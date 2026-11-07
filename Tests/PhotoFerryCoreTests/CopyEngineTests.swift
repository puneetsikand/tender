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

    @Test func existingDestinationIsNeverOverwritten() async throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (a, aData) = try makeSource("IMG_0002.CR3", bytes: 2_000_000)
        let taken = dest("A", a.fileName)
        try FileManager.default.createDirectory(at: taken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: taken)

        let summary = await run([CopyRequest(source: a, destinations: [taken, dest("B", a.fileName)])])
        let result = try #require(summary.results.first)
        #expect(!result.succeeded && !summary.allSucceeded)
        #expect(result.destinations[0] == .failed(taken, reason: "destination already exists"))
        #expect(result.destinations[1].isWritten)          // the other destination still gets its copy
        #expect(try Data(contentsOf: taken) == Data("keep me".utf8))
        #expect(try Data(contentsOf: dest("B", a.fileName)) == aData)
        #expect(partials(under: tmp).isEmpty)
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
