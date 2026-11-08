import Foundation
import Testing
@testable import IngestUI
@testable import PhotoFerryCore

@MainActor @Suite struct JobProgressTests {
    let files = (1...2).map { i in
        SourceFile(url: URL(fileURLWithPath: "/card/DCIM/F\(i).DNG"), relativePath: "DCIM/F\(i).DNG",
                   size: Int64(i) * 10_000_000, modificationDate: nil, kind: .raw)
    }

    func job() -> CopyJob {
        CopyJob(source: JobSource(root: URL(fileURLWithPath: "/card")), destinationRoots: [URL(fileURLWithPath: "/lib")],
                requests: files.map { CopyRequest(source: $0, destinations: [URL(fileURLWithPath: "/lib/\($0.fileName)")]) },
                options: CopyOptions())
    }

    func result(_ i: Int, ok: Bool) -> FileCopyResult {
        let f = files[i]
        let dest = URL(fileURLWithPath: "/lib/\(f.fileName)")
        return FileCopyResult(request: CopyRequest(source: f, destinations: [dest]), sourceSHA256: ok ? "ab" : nil,
                              bytesRead: f.size, sourceError: ok ? nil : "read: I/O error",
                              destinations: [ok ? .written(dest, DestinationVerification(mode: .hash, path: .device, destinationSHA256: "ab"))
                                                : .failed(dest, reason: "source: read: I/O error")])
    }

    @Test func tracksStatesBytesAndOutcome() {
        let p = JobProgress(job: job(), runnerName: "test")
        #expect(p.totalBytes == 30_000_000 && p.fraction == 0 && p.isRunning)

        p.apply(.fileStarted(index: 0, files[0]))
        p.apply(.progress(index: 0, bytesDone: 4_000_000))
        p.apply(.progress(index: 0, bytesDone: 10_000_000))
        #expect(p.bytesDone == 10_000_000)
        p.apply(.verifying(index: 0))
        #expect(p.rows[0].state == .verifying)
        p.apply(.fileFinished(index: 0, result(0, ok: true)))
        guard case .done(let v, _) = p.rows[0].state else { Issue.record("not done"); return }
        #expect(v?.path == .device)

        // A file that finishes without progress events still counts its full size once.
        p.apply(.fileStarted(index: 1, files[1]))
        p.apply(.fileFinished(index: 1, result(1, ok: false)))
        #expect(p.bytesDone == 30_000_000 && p.fraction == 1)
        #expect(p.filesDone == 1 && p.filesFailed == 1)

        p.apply(.finished(CopySummary(results: [result(0, ok: true), result(1, ok: false)], bytesRead: 30_000_000, elapsed: .seconds(1))))
        #expect(!p.isRunning)
        #expect(p.summary?.allSucceeded == false)
    }

    @Test func interruptionFailsEveryUnsettledFile() {
        let p = JobProgress(job: job(), runnerName: "test")
        p.apply(.fileStarted(index: 0, files[0]))
        p.apply(.fileFinished(index: 0, result(0, ok: true)))
        p.apply(.fileStarted(index: 1, files[1]))
        p.apply(.interrupted(reason: "copy service connection lost"))
        #expect(!p.isRunning)
        guard case .done = p.rows[0].state else { Issue.record("finished file must stay done"); return }
        guard case .failed(let why) = p.rows[1].state else { Issue.record("unsettled file must fail"); return }
        #expect(why.contains("copy service connection lost"))
    }
}

@MainActor @Suite struct JobCancelTests {
    @Test func cancellingMarksUnfinishedFilesNotCopied() {
        let f = SourceFile(url: URL(fileURLWithPath: "/c/A.DNG"), relativePath: "A.DNG", size: 10, modificationDate: nil, kind: .raw)
        let job = CopyJob(source: JobSource(root: URL(fileURLWithPath: "/c")), destinationRoots: [],
                          requests: [CopyRequest(source: f, destinations: [URL(fileURLWithPath: "/l/A.DNG")])], options: CopyOptions())
        let p = JobProgress(job: job, runnerName: "t")
        p.apply(.fileStarted(index: 0, f))
        p.markCancelled()
        #expect(p.cancelled && !p.isRunning)
        guard case .failed(let why) = p.rows[0].state else { Issue.record("expected failed"); return }
        #expect(why == "not copied: cancelled")
    }
}
