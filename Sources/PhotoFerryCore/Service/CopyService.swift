import Foundation
import os
import Synchronization
import XPC

/// The wire protocol between a host app and the copy service. Codable messages over XPC.
public enum CopyService {
    /// The service's bundle identifier; also its XPC service name.
    public static let name = "local.photoferry.copyservice"

    public enum Request: Codable, Sendable {
        case start(CopyJob)
        case cancel(job: UUID)
    }

    public enum Reply: Codable, Sendable {
        case accepted
        case cancelled
    }

    /// Service → host. Delivered in order on the session.
    public struct Event: Codable, Sendable {
        public let job: UUID
        public let event: CopyEvent
    }
}

// MARK: - Service side

/// One connected host. Jobs outlive the connection: if the host crashes or quits mid-copy,
/// the job runs to completion so no file is left half-done, and the ledger records the
/// outcome for the host to read when it comes back.
public final class CopyServicePeer: XPCPeerHandler {
    let session: XPCSession
    let ledger: Ledger?
    let uploads: UploadWorker?
    let jobs = Mutex<[UUID: Task<Void, Never>]>([:])
    static let log = Logger(subsystem: CopyService.name, category: "service")

    public init(session: XPCSession, ledger: Ledger?, uploads: UploadWorker? = nil) {
        self.session = session
        self.ledger = ledger
        self.uploads = uploads
    }

    public func handleIncomingRequest(_ request: CopyService.Request) -> (any Encodable)? {
        switch request {
        case let .start(copyJob):
            let job = copyJob.id
            Self.log.notice("job \(job, privacy: .public): \(copyJob.requests.count) files")
            // Hold an XPC transaction so launchd doesn't reclaim the service mid-job.
            xpc_transaction_begin()
            let session = session
            let task = Task { [self] in
                for await event in JobExecutor(ledger: self.ledger).run(copyJob) {
                    try? session.send(CopyService.Event(job: job, event: event))   // fails harmlessly if the host is gone
                    if case .finished(let s) = event {
                        Self.log.notice("job \(job, privacy: .public) finished: \(s.results.count) files, \(s.failed.count) failed")
                    }
                }
                self.jobs.withLock { $0[job] = nil }
                xpc_transaction_end()
                // Start any uploads the job queued now, rather than at the next poll.
                if let uploads = self.uploads { Task { _ = await uploads.runUntilIdle() } }
            }
            jobs.withLock { $0[job] = task }
            return CopyService.Reply.accepted

        case .cancel(let job):
            jobs.withLock { $0[job] }?.cancel()
            return CopyService.Reply.cancelled
        }
    }

    public func handleCancellation(error: XPCRichError) {
        let running = jobs.withLock { $0.count }
        Self.log.notice("host disconnected; \(running) job(s) keep running")
    }
}

// MARK: - Host side

/// Runs jobs in the bundled copy service.
public final class XPCCopyRunner: CopyRunner {
    public var name: String { "xpc:\(CopyService.name)" }
    private let router: Router
    private let session: XPCSession

    public init() throws {
        let router = Router()
        self.router = router
        session = try XPCSession(
            xpcService: CopyService.name,
            incomingMessageHandler: { (message: CopyService.Event) -> (any Encodable)? in
                router.deliver(message)
                return nil
            },
            cancellationHandler: { error in router.interruptAll("copy service connection lost: \(error)") })
    }

    deinit { session.cancel(reason: "runner released") }

    public func run(_ copyJob: CopyJob) -> AsyncStream<CopyEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CopyEvent.self, bufferingPolicy: .unbounded)
        let job = copyJob.id
        router.add(job, continuation)
        let session = session
        let router = router
        continuation.onTermination = { reason in
            if case .cancelled = reason { try? session.send(CopyService.Request.cancel(job: job)) }
            router.remove(job)
        }
        do {
            try session.send(CopyService.Request.start(copyJob)) {
                (reply: Result<CopyService.Reply, any Error>) in
                if case .failure(let error) = reply { router.interrupt(job, "copy service refused the job: \(error)") }
            }
        } catch {
            router.interrupt(job, "could not reach copy service: \(error)")
        }
        return stream
    }

    /// Routes service events to the stream of the job they belong to.
    final class Router: Sendable {
        private let streams = Mutex<[UUID: AsyncStream<CopyEvent>.Continuation]>([:])

        func add(_ job: UUID, _ c: AsyncStream<CopyEvent>.Continuation) { streams.withLock { $0[job] = c } }
        func remove(_ job: UUID) { _ = streams.withLock { $0.removeValue(forKey: job) } }

        func deliver(_ message: CopyService.Event) {
            guard let c = streams.withLock({ $0[message.job] }) else { return }
            c.yield(message.event)
            if case .finished = message.event { c.finish() }
        }

        func interrupt(_ job: UUID, _ reason: String) {
            guard let c = streams.withLock({ $0.removeValue(forKey: job) }) else { return }
            c.yield(.interrupted(reason: reason))
            c.finish()
        }

        func interruptAll(_ reason: String) {
            let all = streams.withLock { s in defer { s.removeAll() }; return Array(s.values) }
            for c in all { c.yield(.interrupted(reason: reason)); c.finish() }
        }
    }
}
