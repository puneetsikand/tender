import Foundation
import GRDB
import Synchronization
import Testing
@testable import PhotoFerryCore

@Suite struct AutoRunMatcherTests {
    func wf(_ name: String, cards: [String] = [], serials: [String] = []) -> Workflow {
        var w = Workflow.starter(name: name)
        w.autoRun = .init(cardKeys: cards, bodySerials: serials)
        return w
    }
    let fp = ["91420511": "SIGMA fp"]

    @Test func noRulesMeansNoAutoRun() {
        #expect(AutoRunMatcher.decide(workflows: [wf("A")], cardKey: "sd:x", bodySerials: fp) == .none)
    }

    @Test func cameraRuleRunsForASingleBodyCard() {
        let d = AutoRunMatcher.decide(workflows: [wf("A"), wf("fp", serials: ["91420511"])], cardKey: nil, bodySerials: fp)
        #expect(d == .run(workflow: "fp", reason: "photos from SIGMA fp #91420511 run “fp”"))
    }

    @Test func cardRuleBeatsCameraRuleAndWorksWithMixedBodies() {
        let ws = [wf("fp", serials: ["91420511"]), wf("video card", cards: ["sd:03-5344-SK32G-8.5-4984c954"])]
        let mixed = ["91420511": "SIGMA fp", "123": "Other"]
        guard case .run(let name, _) = AutoRunMatcher.decide(workflows: ws, cardKey: "sd:03-5344-SK32G-8.5-4984c954", bodySerials: mixed)
        else { Issue.record("expected run"); return }
        #expect(name == "video card")
    }

    @Test func mixedBodiesHoldBackACameraRule() {
        let d = AutoRunMatcher.decide(workflows: [wf("fp", serials: ["91420511"])], cardKey: nil,
                                      bodySerials: ["91420511": "SIGMA fp", "123": "Other"])
        #expect(d == .held(reason: "files from 2 cameras are on this card; choose a workflow"))
    }

    @Test func twoMatchingWorkflowsHoldBack() {
        let ws = [wf("A", serials: ["91420511"]), wf("B", serials: ["91420511"])]
        #expect(AutoRunMatcher.decide(workflows: ws, cardKey: nil, bodySerials: fp)
                == .held(reason: "2 workflows are set to run for this camera; choose one"))
        let byCard = [wf("A", cards: ["k"]), wf("B", cards: ["k"])]
        #expect(AutoRunMatcher.decide(workflows: byCard, cardKey: "k", bodySerials: [:])
                == .held(reason: "2 workflows are set to run for this card; choose one"))
    }
}

@Suite struct CardCleanerTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-clean-\(UUID().uuidString)")

    /// Copies a fake card with the real executor; returns the card root, the summary and the ledger.
    func copied(_ names: [String], extraOnCard: [String] = [], onClash: ClashPolicy = .keepBoth,
                occupy: String? = nil) async throws -> (URL, CopySummary, UUID, Ledger) {
        let card = tmp.appendingPathComponent("card")
        for n in names + extraOnCard {
            let url = card.appendingPathComponent("DCIM/100TEST/\(n)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(n.utf8 + Data(repeating: 7, count: 20_000)).write(to: url)
        }
        let files = try CardScanner().scan(card).filter { names.contains($0.fileName) }
        let lib = tmp.appendingPathComponent("lib")
        if let occupy {
            try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
            try Data("different".utf8).write(to: lib.appendingPathComponent(occupy))
        }
        let ledger = try Ledger(url: tmp.appendingPathComponent("ledger.sqlite"))
        let job = CopyJob(source: JobSource(root: card), destinationRoots: [lib],
                          requests: files.map { CopyRequest(source: $0, destinations: [lib.appendingPathComponent($0.fileName)]) },
                          options: CopyOptions(chunkSize: 1 << 16, onClash: onClash))
        var summary: CopySummary?
        for await e in JobExecutor(ledger: ledger).run(job) { if case .finished(let s) = e { summary = s } }
        return (card, try #require(summary), job.id, ledger)
    }

    func onCard(_ card: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: card.appendingPathComponent("DCIM/100TEST").path)) ?? [])
    }

    @Test func deletesExactlyTheVerifiedFilesOfTheJobAndRecordsIt() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (card, summary, id, ledger) = try await copied(["A.DNG", "A.JPG"], extraOnCard: ["B.MOV"])
        let report = try CardCleaner.deleteVerifiedSources(of: summary, cardRoot: card, jobID: id, ledger: ledger)
        #expect(Set(report.deleted) == ["DCIM/100TEST/A.DNG", "DCIM/100TEST/A.JPG"] && report.kept.isEmpty)
        #expect(onCard(card) == ["B.MOV"])                                       // not in the job: untouched
        let marked = try await ledger.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file WHERE deletedFromSourceAt IS NOT NULL") }
        #expect(marked == 2)
    }

    @Test func refusesUnlessEveryFileVerified() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (card, summary, id, ledger) = try await copied(["A.DNG", "C.DNG"], onClash: .fail, occupy: "C.DNG")
        #expect(!summary.allSucceeded)
        #expect(throws: CardCleaner.Refusal.notAllVerified) {
            try CardCleaner.deleteVerifiedSources(of: summary, cardRoot: card, jobID: id, ledger: ledger)
        }
        #expect(onCard(card) == ["A.DNG", "C.DNG"])                              // nothing deleted, not even A
        #expect(throws: CardCleaner.Refusal.emptyJob) {
            try CardCleaner.deleteVerifiedSources(of: CopySummary(results: [], bytesRead: 0, elapsed: .zero), cardRoot: card, jobID: id, ledger: nil)
        }
    }

    @Test func keepsFilesThatChangedOrLostTheirCopy() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (card, summary, id, ledger) = try await copied(["A.DNG", "B.DNG", "C.DNG"])
        try Data("rewritten on card".utf8).write(to: card.appendingPathComponent("DCIM/100TEST/B.DNG"))
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("lib/C.DNG"))
        let report = try CardCleaner.deleteVerifiedSources(of: summary, cardRoot: card, jobID: id, ledger: ledger)
        #expect(report.deleted == ["DCIM/100TEST/A.DNG"])
        #expect(Dictionary(uniqueKeysWithValues: report.kept.map { ($0.path, $0.reason) }) == [
            "DCIM/100TEST/B.DNG": "changed on the card since it was copied",
            "DCIM/100TEST/C.DNG": "a copy is missing or changed at its destination"])
        #expect(onCard(card) == ["B.DNG", "C.DNG"])
    }
}

/// Network-share hardening: a destination volume that disappears mid-copy.
@Suite(.serialized) struct DisappearingDestinationTests {
    @Test(.timeLimit(.minutes(2)))
    func vanishingDestinationFailsAloneAndTheOtherCompletes() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-vanish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("card/DCIM/100TEST")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 1...8 { try Data(repeating: UInt8(i), count: 24 << 20).write(to: src.appendingPathComponent("CLIP000\(i).MOV")) }
        let files = try CardScanner().scan(tmp.appendingPathComponent("card"))

        let label = "PFNAS\(Int.random(in: 1000...9999))"
        let dmg = tmp.appendingPathComponent("\(label).dmg")
        let mount = tmp.appendingPathComponent("nas")
        try VolumeMonitorTests.hdiutil("create", "-quiet", "-size", "400m", "-fs", "ExFAT", "-volname", label, dmg.path)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try VolumeMonitorTests.hdiutil("attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, dmg.path)
        defer { _ = try? VolumeMonitorTests.hdiutil("detach", "-quiet", "-force", mount.path) }

        let local = tmp.appendingPathComponent("lib")
        let requests = files.map { CopyRequest(source: $0, destinations: [local.appendingPathComponent($0.fileName), mount.appendingPathComponent($0.fileName)]) }
        // The "NAS" drops off right after the second file's copy to it is sealed, from inside the
        // engine, so the timing doesn't depend on how fast the test consumes events.
        let dropped = Mutex(false)
        let mountPath = mount.path
        let engine = CopyEngine(options: CopyOptions(chunkSize: 1 << 20, filesInFlight: 1), afterSeal: { partial in
            guard partial.path.hasPrefix(mountPath), partial.lastPathComponent.contains("CLIP0002") else { return }
            let first = dropped.withLock { d in defer { d = true }; return !d }
            if first { _ = try? VolumeMonitorTests.hdiutil("detach", "-quiet", "-force", mountPath) }
        }, beforeSourceReread: nil)
        var summary: CopySummary?
        for await e in engine.run(requests, destinationRoots: [local, mount]) {
            if case .finished(let s) = e { summary = s }
        }
        let detached = dropped.withLock { $0 }
        let s = try #require(summary)
        #expect(detached && s.results.count == 8)
        // Every file still reached the local destination, verified.
        #expect(s.results.allSatisfy { $0.destinations[0].isSatisfied })
        for f in files { #expect(FileManager.default.contentsEqual(atPath: f.url.path, andPath: local.appendingPathComponent(f.fileName).path)) }
        // The first file reached the NAS; the one being verified when it dropped, and every one
        // after, failed for the vanished destination and say so.
        #expect(s.results[0].destinations[1].isSatisfied)
        let lost = s.results.dropFirst().map { $0.destinations[1] }
        #expect(lost.allSatisfy { !$0.isSatisfied })
        #expect(!s.allSucceeded)
        guard case .failed(_, let reason) = lost.last else { Issue.record("expected failure"); return }
        #expect(reason.contains("no longer available"))
        // And nothing landed in the leftover mount-point folder on the internal disk.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: mount.path)) ?? []
        #expect(leftovers.filter { !$0.hasPrefix(".") }.isEmpty, "wrote to the boot disk: \(leftovers)")
    }
}

@Suite struct DestinationGuardTests {
    @Test func unmountedVolumePathIsRefusedAndNeverCreated() {
        let g = DestinationGuard(roots: [URL(fileURLWithPath: "/Volumes/PFNoSuchShare\(Int.random(in: 1000...9999))/Photos")])
        let problem = g.problem(for: g.roots[0].path.appendingPathComponent("2026/A.DNG"))
        #expect(problem?.contains("isn't connected") == true)
        #expect(!FileManager.default.fileExists(atPath: (g.roots[0].path as NSString).deletingLastPathComponent))
    }

    @Test func localRootIsCreatedAndAccepted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pf-guard-\(UUID().uuidString)/lib")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let g = DestinationGuard(roots: [root])
        #expect(g.problem(for: root.appendingPathComponent("x/A.DNG")) == nil)
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(g.problem(for: URL(fileURLWithPath: "/elsewhere/A.DNG")) == nil)   // not under a guarded root
    }
}

private extension String {
    func appendingPathComponent(_ c: String) -> URL { URL(fileURLWithPath: self).appendingPathComponent(c) }
}

@Suite struct StillBeingWrittenTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-settle-\(UUID().uuidString)")

    func file(_ name: String, bytes: Int) throws -> SourceFile {
        let url = tmp.appendingPathComponent("card/DCIM/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return SourceFile(url: url, relativePath: "DCIM/\(name)", size: Int64(bytes), modificationDate: nil, kind: .raw)
    }

    @Test func detectsEmptyAndGrowingFiles() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let done = try file("A.RAF", bytes: 1000), empty = try file("B.RAF", bytes: 0), growing = try file("C.RAF", bytes: 500)
        let h = try FileHandle(forWritingTo: growing.url); try h.seekToEnd(); try h.write(contentsOf: Data(count: 500)); try h.close()
        #expect(WriteSettle.empty([done, empty, growing]) == ["DCIM/B.RAF"])
        #expect(WriteSettle.changedSinceScan([done, empty, growing]) == ["DCIM/C.RAF"])
    }

    @Test func engineRefusesAFileThatGrewSinceTheScan() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let scanned = try file("GFXR1509.RAF", bytes: 300_000)
        let h = try FileHandle(forWritingTo: scanned.url); try h.seekToEnd(); try h.write(contentsOf: Data(count: 200_000)); try h.close()
        let dest = tmp.appendingPathComponent("lib/GFXR1509.RAF")
        var result: FileCopyResult?
        for await e in CopyEngine(options: CopyOptions(chunkSize: 1 << 16)).run([CopyRequest(source: scanned, destinations: [dest])]) {
            if case .finished(let s) = e { result = s.results.first }
        }
        let r = try #require(result)
        #expect(!r.succeeded)
        #expect(r.sourceError?.contains("changed size while it was being read") == true)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)) ?? []).isEmpty)
    }
}
