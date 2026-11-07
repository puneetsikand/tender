import Foundation
import Observation
import PhotoFerryCore

/// Live state of one running (or finished) job, fed by `CopyEvent`s.
@Observable @MainActor
public final class JobProgress {
    public enum FileState: Equatable {
        case queued
        case copying(bytes: Int64)
        case verifying
        case done(DestinationVerification?)
        case failed(String)
    }

    public struct Row: Identifiable {
        public let id: Int
        public let request: CopyRequest
        public var state: FileState = .queued
    }

    public let job: CopyJob
    public let runnerName: String
    public private(set) var rows: [Row]
    public private(set) var summary: CopySummary?
    public private(set) var interruption: String?
    public private(set) var notices: [String] = []
    public let startedAt = Date.now
    public let totalBytes: Int64
    public private(set) var bytesDone: Int64 = 0
    /// Bytes per second over the last few seconds.
    public private(set) var throughput: Double = 0
    private var samples: [(time: ContinuousClock.Instant, bytes: Int64)] = []
    private var perFile: [Int: Int64] = [:]

    public init(job: CopyJob, runnerName: String) {
        self.job = job
        self.runnerName = runnerName
        rows = job.requests.enumerated().map { Row(id: $0.offset, request: $0.element) }
        totalBytes = job.requests.reduce(0) { $0 + $1.source.size }
    }

    public var isRunning: Bool { summary == nil && interruption == nil }
    public var fraction: Double { totalBytes > 0 ? min(1, Double(bytesDone) / Double(totalBytes)) : (isRunning ? 0 : 1) }
    public var filesDone: Int { rows.count { if case .done = $0.state { true } else { false } } }
    public var filesFailed: Int { rows.count { if case .failed = $0.state { true } else { false } } }

    /// Seconds left at the current rate, nil until there is a rate.
    public var secondsRemaining: Double? {
        guard isRunning, throughput > 1 else { return nil }
        return Double(totalBytes - bytesDone) / throughput
    }

    public func apply(_ event: CopyEvent) {
        switch event {
        case .fileStarted(let i, _):
            rows[i].state = .copying(bytes: 0)
        case let .progress(i, bytes):
            bytesDone += bytes - perFile[i, default: 0]
            perFile[i] = bytes
            rows[i].state = .copying(bytes: bytes)
            sample()
        case .verifying(let i):
            rows[i].state = .verifying
        case let .fileFinished(i, result):
            // Count a file's full size once it's settled, even if progress events were coalesced.
            bytesDone += result.bytesRead - perFile[i, default: 0]
            perFile[i] = result.bytesRead
            if result.succeeded {
                let v = result.destinations.compactMap { if case .written(_, let v) = $0 { v } else { nil } }.first
                rows[i].state = .done(v)
            } else {
                let reason = result.sourceError
                    ?? result.destinations.compactMap { if case .failed(let u, let r) = $0 { "\(u.lastPathComponent): \(r)" } else { nil } }.first
                    ?? "failed"
                rows[i].state = .failed(reason)
            }
        case .finished(let s):
            summary = s
            throughput = s.megabytesPerSecond * 1_000_000
        case .interrupted(let reason):
            interruption = reason
            for i in rows.indices where !isSettled(rows[i].state) { rows[i].state = .failed("not copied: \(reason)") }
        case .notice(let text):
            notices.append(text)
        }
    }

    private func isSettled(_ s: FileState) -> Bool {
        switch s { case .done, .failed: true; default: false }
    }

    private func sample() {
        let now = ContinuousClock.now
        samples.append((now, bytesDone))
        samples.removeAll { now - $0.time > .seconds(3) }
        if let first = samples.first, let last = samples.last, last.time > first.time {
            let d = last.time - first.time
            let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            throughput = Double(last.bytes - first.bytes) / seconds
        }
    }
}
