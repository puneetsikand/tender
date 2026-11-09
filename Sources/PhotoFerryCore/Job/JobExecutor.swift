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
                let queued = enqueueUploads(job, summary)
                if queued > 0 { out.yield(.notice("uploads: \(queued) queued for offsite backup")) }
                out.yield(event)
            default:
                out.yield(event)
            }
        }
        if !finished {
            try? ledger?.finishJob(job.id, status: .cancelled, summary: nil, manifests: [:])
        }
    }

    /// Queues bucket uploads for every file that now has a verified local copy: this job's files,
    /// plus earlier copies that were never uploaded. Uploads read the local copy, never the card.
    private func enqueueUploads(_ job: CopyJob, _ summary: CopySummary) -> Int {
        guard let ledger else { return 0 }
        var queued = 0
        for r in summary.results where !r.request.remote.isEmpty {
            guard let sha = r.sourceSHA256, let local = r.destinations.first(where: \.isSatisfied)?.url else { continue }
            for remote in r.request.remote {
                if (try? ledger.enqueueUpload(job: job.id, relativePath: r.request.source.relativePath, localPath: local.path,
                                              sha256: sha, size: r.request.source.size, remote: remote)) == true { queued += 1 }
            }
        }
        for req in job.uploadOnly {
            guard let local = req.destinations.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let sha = try? ledger.sha256(ofCopyAt: local.path) else { continue }
            for remote in req.remote {
                if (try? ledger.enqueueUpload(job: job.id, relativePath: req.source.relativePath, localPath: local.path,
                                              sha256: sha, size: req.source.size, remote: remote)) == true { queued += 1 }
            }
        }
        return queued
    }
}
