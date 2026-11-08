import Foundation

/// Runs a `CopyJob` end to end: engine, ledger records per file, manifests, final status.
/// Both runners use it, so a job in the copy service records itself even if its host is gone.
public struct JobExecutor: Sendable {
    let ledger: Ledger?

    public init(ledger: Ledger?) {
        self.ledger = ledger
    }

    public func run(_ job: CopyJob) -> AsyncStream<CopyEvent> {
        AsyncStream { out in
            let task = Task {
                await execute(job, out)
                out.finish()
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(_ job: CopyJob, _ out: AsyncStream<CopyEvent>.Continuation) async {
        do { try ledger?.beginJob(job) } catch { out.yield(.notice("ledger: could not record job start: \(error)")) }

        var finished = false
        for await event in CopyEngine(options: job.options).run(job.requests, destinationRoots: job.destinationRoots) {
            switch event {
            case .fileFinished(_, let result):
                do { try ledger?.recordFile(job: job.id, result) } catch { out.yield(.notice("ledger: \(error)")) }
                out.yield(event)
            case .finished(let summary):
                finished = true
                var manifests: [URL: URL] = [:]
                do { manifests = try ManifestWriter.write(job: job, summary: summary) }
                catch { out.yield(.notice("manifest: could not write: \(error.localizedDescription)")) }
                do { try ledger?.finishJob(job.id, status: .finished, summary: summary, manifests: manifests) }
                catch { out.yield(.notice("ledger: could not record job end: \(error)")) }
                for (root, file) in manifests.sorted(by: { $0.key.path < $1.key.path }) {
                    out.yield(.notice("manifest: \(file.path.dropFirst(root.path.count + 1)) in \(root.path)"))
                }
                out.yield(event)
            default:
                out.yield(event)
            }
        }
        if !finished {
            try? ledger?.finishJob(job.id, status: .cancelled, summary: nil, manifests: [:])
        }
    }
}
