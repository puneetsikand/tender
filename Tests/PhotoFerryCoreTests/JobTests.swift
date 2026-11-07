import Foundation
import GRDB
import Testing
@testable import PhotoFerryCore

@Suite struct JobExecutorTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-job-\(UUID().uuidString)")

    func makeJob(roots: [String]) throws -> CopyJob {
        let card = tmp.appendingPathComponent("card")
        var requests: [CopyRequest] = []
        for (i, name) in ["SDIM0001.DNG", "SDIM0001.JPG", "SDIM0002.DNG"].enumerated() {
            let url = card.appendingPathComponent("DCIM/100SIGMA/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: UInt8(i + 1), count: 200_000 * (i + 1)).write(to: url)
        }
        let files = try CardScanner().scan(card)
        for f in files {
            requests.append(CopyRequest(source: f, destinations: roots.map { tmp.appendingPathComponent("\($0)/2026-11-06/\(f.fileName)") }))
        }
        return CopyJob(source: JobSource(root: card, volumeLabel: "NO NAME", cardKey: "sd:03-5344-SK32G-8.5-4984c954"),
                       destinationRoots: roots.map { tmp.appendingPathComponent($0) }, requests: requests,
                       options: CopyOptions(chunkSize: 1 << 16))
    }

    func drain(_ stream: AsyncStream<CopyEvent>) async -> (CopySummary?, [String]) {
        var summary: CopySummary?
        var notices: [String] = []
        for await e in stream {
            if case .finished(let s) = e { summary = s }
            if case .notice(let n) = e { notices.append(n) }
        }
        return (summary, notices)
    }

    @Test func recordsJobFilesCopiesAndManifestsThatShasumAccepts() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ledger = try Ledger(url: tmp.appendingPathComponent("ledger.sqlite"))
        let job = try makeJob(roots: ["Mac", "NAS"])
        let (summary, notices) = await drain(JobExecutor(ledger: ledger).run(job))
        #expect(summary?.allSucceeded == true)
        #expect(notices.filter { $0.hasPrefix("manifest:") }.count == 2)

        let jobs = try ledger.recentJobs()
        let record = try #require(jobs.first)
        #expect(jobs.count == 1 && record.id == job.id)
        #expect(record.status == .finished)
        #expect(record.filesRecorded == 3 && record.filesTotal == 3 && record.filesFailed == 0)
        #expect(record.cardKey == "sd:03-5344-SK32G-8.5-4984c954")

        // Every copy is findable by content hash: the basis for duplicate checks.
        let hash = try #require(summary?.results.first?.sourceSHA256)
        #expect(try ledger.verifiedCopies(sha256: hash).count == 2)

        // The manifest verifies with the stock tool, from the destination root.
        for root in job.destinationRoots {
            let dir = root.appending(path: ManifestWriter.folder)
            let manifest = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path).first)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
            p.arguments = ["-a", "256", "-c", "\(ManifestWriter.folder)/\(manifest)"]
            p.currentDirectoryURL = root
            let out = Pipe(); p.standardOutput = out
            try p.run(); p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(p.terminationStatus == 0, "shasum: \(text)")
            #expect(text.components(separatedBy: ": OK").count - 1 == 3)
        }
    }

    @Test func failedCopiesAreRecordedAndLeftOutOfTheManifest() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ledger = try Ledger(url: tmp.appendingPathComponent("ledger.sqlite"))
        let job = try makeJob(roots: ["Mac"])
        // Occupy one destination so it fails.
        let taken = job.requests[0].destinations[0]
        try FileManager.default.createDirectory(at: taken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("other".utf8).write(to: taken)

        let (summary, _) = await drain(JobExecutor(ledger: ledger).run(job))
        #expect(summary?.failed.count == 1)
        #expect(try ledger.recentJobs().first?.filesFailed == 1)
        let dir = job.destinationRoots[0].appending(path: ManifestWriter.folder)
        let manifest = try String(contentsOf: dir.appending(path: try FileManager.default.contentsOfDirectory(atPath: dir.path)[0]), encoding: .utf8)
        #expect(manifest.split(separator: "\n").count == 2)
        #expect(!manifest.contains(taken.lastPathComponent))
    }

    @Test func jobLeftRunningByADeadProcessIsMarkedInterrupted() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent("ledger.sqlite")
        let job = try makeJob(roots: ["Mac"])
        try Ledger(url: url).beginJob(job)
        let ledger = try Ledger(url: url)
        #expect(try ledger.recentJobs().first?.status == .running)      // our own pid is alive

        try ledger.pool.write { db in try db.execute(sql: "UPDATE job SET pid = 999999") }   // no such process
        #expect(try Ledger(url: url).recentJobs().first?.status == .interrupted)
    }

    @Test func emptySummaryWritesNoManifest() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let job = CopyJob(source: JobSource(root: tmp), destinationRoots: [tmp.appendingPathComponent("Mac")], requests: [], options: CopyOptions())
        let written = try ManifestWriter.write(job: job, summary: CopySummary(results: [], bytesRead: 0, elapsed: .zero))
        #expect(written.isEmpty)
    }
}
