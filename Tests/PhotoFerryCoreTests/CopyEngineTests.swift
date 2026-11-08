import CryptoKit
import Foundation
import Testing
@testable import PhotoFerryCore

@Suite struct CopyEngineTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-copy-\(UUID().uuidString)")

    func makeSource(_ name: String, bytes: Int) throws -> (SourceFile, Data) {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buf in
            var rng = SystemRandomNumberGenerator()
            for i in stride(from: 0, to: bytes, by: 8) {
                var v = rng.next()
                withUnsafeBytes(of: &v) { word in
                    for j in 0..<min(8, bytes - i) { buf[i + j] = word[j] }
                }
            }
        }
        let url = tmp.appendingPathComponent("src/DCIM/100TEST/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        let mtime = Date(timeIntervalSince1970: 1_780_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let file = SourceFile(url: url, relativePath: "DCIM/100TEST/\(name)", size: Int64(bytes),
                              modificationDate: mtime, kind: MediaKind(fileExtension: url.pathExtension))
        return (file, data)
    }

    func dest(_ root: String, _ name: String) -> URL { tmp.appendingPathComponent("\(root)/2026/\(name)") }

    func run(_ requests: [CopyRequest], _ options: CopyOptions = CopyOptions(chunkSize: 1 << 20)) async -> CopySummary {
        for await event in CopyEngine(options: options).run(requests) {
            if case .finished(let summary) = event { return summary }
        }
        Issue.record("stream ended without .finished")
        return CopySummary(results: [], bytesRead: 0, elapsed: .zero)
    }

    func partials(under root: URL) -> [String] {
        let walker = FileManager.default.enumerator(atPath: root.path)
        return (walker?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".pfpartial") }
    }

    @Test func copiesMultiChunkFilesToTwoDestinationsWithCorrectHash() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (a, aData) = try makeSource("IMG_0001.CR3", bytes: 5 * (1 << 20) + 123)   // 6 chunks, last one short
        let (b, bData) = try makeSource("IMG_0001.JPG", bytes: 300_000)
        let requests = [a, b].map { CopyRequest(source: $0, destinations: [dest("A", $0.fileName), dest("B", $0.fileName)]) }

        let summary = await run(requests)
        #expect(summary.allSucceeded)
        #expect(summary.bytesRead == Int64(aData.count + bData.count))
        for (file, data) in [(a, aData), (b, bData)] {
            let result = try #require(summary.results.first { $0.request.source == file })
            #expect(result.sourceSHA256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            for root in ["A", "B"] {
                let url = dest(root, file.fileName)
                #expect(try Data(contentsOf: url) == data)
                let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
                #expect(mtime == file.modificationDate)
            }
        }
        #expect(partials(under: tmp).isEmpty)
    }

    @Test func differentFileInTheWayIsNeverOverwritten() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (a, aData) = try makeSource("IMG_0002.CR3", bytes: 2_000_000)
        let taken = dest("A", a.fileName)
        try FileManager.default.createDirectory(at: taken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: taken)

        // fail: the copy to A fails, B still gets its copy.
        var summary = await run([CopyRequest(source: a, destinations: [taken, dest("B", a.fileName)])],
                                CopyOptions(chunkSize: 1 << 20, onClash: .fail))
        var result = try #require(summary.results.first)
        #expect(!result.succeeded)
        #expect(result.destinations[0] == .failed(taken, reason: "a different file with this name already exists"))
        #expect(result.destinations[1].isWritten)
        #expect(try Data(contentsOf: taken) == Data("keep me".utf8))

        // keepBoth (the default): the copy lands beside it as "IMG_0002 2.CR3".
        try FileManager.default.removeItem(at: dest("B", a.fileName))
        summary = await run([CopyRequest(source: a, destinations: [taken])])
        result = try #require(summary.results.first)
        let beside = dest("A", "IMG_0002 2.CR3")
        guard case .written(let url, _) = result.destinations[0] else { Issue.record("expected written"); return }
        #expect(url == beside && result.succeeded)
        #expect(try Data(contentsOf: taken) == Data("keep me".utf8))
        #expect(try Data(contentsOf: beside) == aData)
        #expect(partials(under: tmp).isEmpty)
    }

    @Test func identicalFileAlreadyThereIsSkippedAndUntouched() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (a, aData) = try makeSource("IMG_0005.CR3", bytes: 3_000_000)
        let there = dest("A", a.fileName)
        try FileManager.default.createDirectory(at: there.deletingLastPathComponent(), withIntermediateDirectories: true)
        try aData.write(to: there)
        let before = try FileManager.default.attributesOfItem(atPath: there.path)[.modificationDate] as? Date

        let summary = await run([CopyRequest(source: a, destinations: [there, dest("B", a.fileName)])])
        let result = try #require(summary.results.first)
        guard case .alreadyPresent(let url, let v) = result.destinations[0] else { Issue.record("expected alreadyPresent"); return }
        #expect(url == there && v.destinationSHA256 == result.sourceSHA256 && v.path == .device)
        #expect(result.destinations[1].isWritten)
        #expect(result.succeeded && summary.allSucceeded)
        #expect(try FileManager.default.attributesOfItem(atPath: there.path)[.modificationDate] as? Date == before)
        #expect(!FileManager.default.fileExists(atPath: dest("A", "IMG_0005 2.CR3").path))
    }

    @Test(arguments: [ClashPolicy.keepBoth, .fail])
    func sameSizeButDifferentFileIsDetectedByHash(policy: ClashPolicy) async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (a, aData) = try makeSource("IMG_0006.CR3", bytes: 1_500_000)
        let there = dest("A", a.fileName)
        try FileManager.default.createDirectory(at: there.deletingLastPathComponent(), withIntermediateDirectories: true)
        var other = aData
        other[700_000] ^= 0xFF                      // same size, one byte different
        try other.write(to: there)

        let summary = await run([CopyRequest(source: a, destinations: [there])], CopyOptions(chunkSize: 1 << 20, onClash: policy))
        let result = try #require(summary.results.first)
        #expect(try Data(contentsOf: there) == other)            // never overwritten
        switch policy {
        case .keepBoth:
            guard case .written(let url, _) = result.destinations[0] else { Issue.record("expected written"); return }
            #expect(url.lastPathComponent == "IMG_0006 2.CR3")
            #expect(try Data(contentsOf: url) == aData)
        case .fail:
            #expect(result.destinations[0] == .failed(there, reason: "a different file with this name already exists"))
        }
        #expect(partials(under: tmp).isEmpty)
    }

    @Test func rerunningAFinishedJobSkipsEverythingAndSucceeds() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sources = try (1...3).map { try makeSource("IMG_000\($0).JPG", bytes: 400_000 * $0).0 }
        let requests = sources.map { CopyRequest(source: $0, destinations: [dest("A", $0.fileName), dest("B", $0.fileName)]) }
        #expect(await run(requests).allSucceeded)
        let again = await run(requests)
        #expect(again.allSucceeded)
        #expect(again.results.allSatisfy { r in r.destinations.allSatisfy { if case .alreadyPresent = $0 { true } else { false } } })
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("A/2026").path)
        #expect(names.count == 3)                                 // no " 2" duplicates
    }

    @Test func unwritableDestinationFailsAloneWithoutStoppingOthers() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (a, aData) = try makeSource("IMG_0003.CR3", bytes: 1_500_000)
        let locked = tmp.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        let summary = await run([CopyRequest(source: a, destinations: [locked.appendingPathComponent(a.fileName), dest("B", a.fileName)])])
        let result = try #require(summary.results.first)
        #expect(!result.destinations[0].isWritten)
        #expect(result.destinations[1].isWritten)
        #expect(try Data(contentsOf: dest("B", a.fileName)) == aData)
    }

    @Test func emptyFileCopies() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (a, _) = try makeSource("EMPTY.JPG", bytes: 0)
        let summary = await run([CopyRequest(source: a, destinations: [dest("A", a.fileName)])])
        #expect(summary.allSucceeded)
        #expect(summary.results.first?.sourceSHA256 == SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined())
        #expect(FileManager.default.fileExists(atPath: dest("A", a.fileName).path))
    }

    @Test func missingSourceFailsEveryDestination() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ghost = SourceFile(url: tmp.appendingPathComponent("nope.CR3"), relativePath: "nope.CR3",
                               size: 10, modificationDate: nil, kind: .raw)
        let summary = await run([CopyRequest(source: ghost, destinations: [dest("A", "nope.CR3")])])
        let result = try #require(summary.results.first)
        #expect(result.sourceError != nil && result.sourceSHA256 == nil)
        #expect(!FileManager.default.fileExists(atPath: dest("A", "nope.CR3").path))
    }

    @Test func emptyJobAndDestinationlessRequestAreNotSuccess() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(!(await run([])).allSucceeded)
        let (a, _) = try makeSource("IMG_0004.JPG", bytes: 10)
        #expect(!(await run([CopyRequest(source: a, destinations: [])])).allSucceeded)
    }

    @Test func cancellingLeavesNoPartialsOrFinalFiles() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (a, _) = try makeSource("BIG.MOV", bytes: 64 << 20)
        let target = dest("A", a.fileName)
        let task = Task {
            for await event in CopyEngine(options: CopyOptions(chunkSize: 1 << 20)).run([CopyRequest(source: a, destinations: [target])]) {
                if case .progress(_, let done) = event, done >= 4 << 20 { return }   // dropping the stream cancels the job
            }
        }
        await task.value
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(partials(under: tmp).isEmpty)
    }
}

/// Fault injection: every verification mode must catch the faults it claims to catch (PLAN §11).
@Suite struct VerificationTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-verify-\(UUID().uuidString)")

    func source(bytes: Int = 3 * (1 << 20) + 17) throws -> SourceFile {
        let url = tmp.appendingPathComponent("src/DCIM/100TEST/IMG_0001.CR3")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: url)
        return SourceFile(url: url, relativePath: "DCIM/100TEST/IMG_0001.CR3", size: Int64(bytes), modificationDate: nil, kind: .raw)
    }

    func run(_ engine: CopyEngine, _ file: SourceFile, roots: [String]) async throws -> FileCopyResult {
        let request = CopyRequest(source: file, destinations: roots.map { tmp.appendingPathComponent("\($0)/\(file.fileName)") })
        for await event in engine.run([request]) {
            if case .finished(let s) = event { return try #require(s.results.first) }
        }
        throw CancellationError()
    }

    /// Flips one byte in the middle of the file.
    static func flipByte(_ url: URL) {
        guard let h = try? FileHandle(forUpdating: url), let size = try? h.seekToEnd(), size > 0 else { return }
        try? h.seek(toOffset: size / 2)
        let b = (try? h.read(upToCount: 1))?.first ?? 0
        try? h.seek(toOffset: size / 2)
        try? h.write(contentsOf: Data([b ^ 0xFF]))
        try? h.close()
    }

    static func truncate(_ url: URL) {
        guard let h = try? FileHandle(forUpdating: url) else { return }
        try? h.truncate(atOffset: 1000)
        try? h.close()
    }

    func assertNoTraces(_ root: String, _ file: SourceFile) {
        let dir = tmp.appendingPathComponent(root)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(file.fileName).path))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(left.isEmpty, "left behind: \(left)")
    }

    @Test(arguments: [VerifyMode.hash, .paranoid, .bytes])
    func corruptedCopyIsCaughtAndNeverGetsItsFinalName(mode: VerifyMode) async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try source()
        let bad = tmp.appendingPathComponent("A").path
        let engine = CopyEngine(options: CopyOptions(chunkSize: 1 << 20, verify: mode),
                                afterSeal: { url in if url.path.hasPrefix(bad) { Self.flipByte(url) } },
                                beforeSourceReread: nil)
        let result = try await run(engine, file, roots: ["A", "B"])
        guard case .failed(_, let reason) = result.destinations[0] else { Issue.record("corruption not caught in \(mode)"); return }
        #expect(reason.hasPrefix("verification failed"))
        #expect(result.destinations[1].isWritten)          // the good copy still lands
        assertNoTraces("A", file)
    }

    @Test(arguments: [VerifyMode.size, .hash, .paranoid, .bytes])
    func truncatedCopyIsCaughtByEveryMode(mode: VerifyMode) async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try source()
        let engine = CopyEngine(options: CopyOptions(chunkSize: 1 << 20, verify: mode),
                                afterSeal: { Self.truncate($0) }, beforeSourceReread: nil)
        let result = try await run(engine, file, roots: ["A"])
        #expect(!result.succeeded)
        assertNoTraces("A", file)
    }

    @Test func sizeModeDoesNotClaimToCatchCorruption() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try source()
        let engine = CopyEngine(options: CopyOptions(chunkSize: 1 << 20, verify: .size),
                                afterSeal: { Self.flipByte($0) }, beforeSourceReread: nil)
        let result = try await run(engine, file, roots: ["A"])
        guard case .written(_, let v) = result.destinations[0] else { Issue.record("expected written"); return }
        #expect(v.mode == .size && v.path == .notRead)   // honestly labelled as unread
    }

    @Test func paranoidCatchesASourceThatReadsDifferentlyTheSecondTime() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try source()
        let engine = CopyEngine(options: CopyOptions(chunkSize: 1 << 20, verify: .paranoid),
                                afterSeal: nil, beforeSourceReread: { Self.flipByte($0) })
        let result = try await run(engine, file, roots: ["A", "B"])
        #expect(result.sourceError?.hasPrefix("source read unstable") == true)
        #expect(result.destinations.allSatisfy { !$0.isWritten })
        assertNoTraces("A", file)
        assertNoTraces("B", file)
    }

    @Test func hashModeOnLocalDiskVerifiesFromTheDevice() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try source()
        let result = try await run(CopyEngine(options: CopyOptions(chunkSize: 1 << 20)), file, roots: ["A"])
        guard case .written(_, let v) = result.destinations[0] else { Issue.record("expected written"); return }
        #expect(v.mode == .hash)
        #expect(v.path == .device)
        #expect(v.destinationSHA256 == result.sourceSHA256)
    }
}
