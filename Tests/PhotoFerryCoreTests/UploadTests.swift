import CryptoKit
import Foundation
import GRDB
import Testing
@testable import PhotoFerryCore

/// Everything that uses the shared MockS3 runs one test at a time (suites otherwise run in parallel
/// and would reset the mock under each other).
@Suite(.serialized) enum MockS3Tests {
    @Suite struct MockS3SelfTest {
        @Test func uploadBodiesReachTheMock() async throws {
            MockS3.reset()
            let s3 = S3Client(endpoint: S3Endpoint(host: "mock.s3.test", bucket: "b"), keyID: "k", secret: "s", session: MockS3.session)
            let body = Data("hello".utf8)
            _ = try await s3.put("x.txt", body: body)
            #expect(MockS3.state.withLock { $0.objects["b/x.txt"] } == body)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pf-mock-\(UUID().uuidString)")
            try Data("from file".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            _ = try await s3.putFile("y.txt", file: file, sha256: MockS3.hex(SHA256.hash(data: Data("from file".utf8))))
            #expect(MockS3.state.withLock { $0.objects["b/y.txt"] } == Data("from file".utf8))
        }
    }

    @Suite struct UploadWorkerTests {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-up-\(UUID().uuidString)")
        let target = S3Target(host: "mock.s3.test", bucket: "b", prefix: "backup", keyID: "k")

        func setUp() throws -> Ledger {
            MockS3.reset()
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            return try Ledger(url: tmp.appendingPathComponent("ledger.sqlite"))
        }

        func localFile(_ name: String, bytes: Int) throws -> (URL, String) {
            var d = Data(count: bytes)
            d.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: i &* 7 &+ bytes) } }
            let url = tmp.appendingPathComponent(name)
            try d.write(to: url)
            return (url, MockS3.hex(SHA256.hash(data: d)))
        }

        func worker(_ ledger: Ledger) -> UploadWorker {
            UploadWorker(ledger: ledger, secret: { _ in "s" }, session: MockS3.session, singlePutLimit: 100_000, partSize: 64 * 1024)
        }

        func enqueue(_ ledger: Ledger, _ url: URL, _ sha: String, key: String) throws {
            let size = Int64(try Data(contentsOf: url).count)
            try ledger.enqueueUpload(job: nil, relativePath: "DCIM/\(url.lastPathComponent)", localPath: url.path, sha256: sha, size: size,
                                     remote: RemoteDestination(destinationID: "b2", target: target, key: target.key(for: key)))
        }

        func record(_ ledger: Ledger) throws -> UploadRecord { try #require(try ledger.uploads().first) }

        @Test func singleAndMultipartUploadsLandByteIdentical() async throws {
            defer { try? FileManager.default.removeItem(at: tmp) }
            let ledger = try setUp()
            let (small, smallSHA) = try localFile("A.JPG", bytes: 50_000)
            let (big, bigSHA) = try localFile("B.RAF", bytes: 300_000)                     // 5 parts of 64 KB
            try enqueue(ledger, small, smallSHA, key: "2026/A.JPG")
            try enqueue(ledger, big, bigSHA, key: "2026/B.RAF")
            let summary = await worker(ledger).runUntilIdle()
            #expect(summary == UploadWorker.Summary(done: 2, failed: 0, retried: 0))
            #expect(MockS3.state.withLock { $0.objects["b/backup/2026/A.JPG"] } == (try Data(contentsOf: small)))
            #expect(MockS3.state.withLock { $0.objects["b/backup/2026/B.RAF"] } == (try Data(contentsOf: big)))
            #expect(try ledger.uploads().allSatisfy { $0.state == .done })
            #expect(try ledger.uploads().first { $0.key.hasSuffix("B.RAF") }?.etag == "x-1")    // read from the XML body
        }

        @Test func multipartResumesWithoutReuploadingFinishedParts() async throws {
            defer { try? FileManager.default.removeItem(at: tmp) }
            let ledger = try setUp()
            let (big, sha) = try localFile("C.RAF", bytes: 300_000)
            try enqueue(ledger, big, sha, key: "C.RAF")
            MockS3.state.withLock { $0.failPartNumbers = [3] }
            let first = await worker(ledger).runUntilIdle()
            #expect(first.retried == 1)
            var r = try record(ledger)
            #expect(r.state == .queued && r.multipartID != nil && r.bytesDone == 2 * 64 * 1024 && r.notBefore != nil)

            try ledger.updateUpload(r.id, "notBefore = NULL", [])                          // skip the backoff wait
            let second = await worker(ledger).runUntilIdle()
            #expect(second.done == 1)
            r = try record(ledger)
            #expect(r.state == .done)
            #expect(MockS3.state.withLock { $0.objects["b/backup/C.RAF"] } == (try Data(contentsOf: big)))
            let partPuts = MockS3.state.withLock { $0.requests.filter { $0.hasPrefix("PUT") && $0.contains("partNumber") } }
            #expect(partPuts.count == 1 + 2 + 3)          // run 1: parts 1, 2, failed 3; run 2: only 3, 4, 5
        }

        @Test(arguments: [50_000, 300_000])
        func aLocalCopyThatNoLongerMatchesTheCardIsNeverUploaded(bytes: Int) async throws {
            defer { try? FileManager.default.removeItem(at: tmp) }
            let ledger = try setUp()
            let (url, cardSHA) = try localFile("D.RAF", bytes: bytes)
            try enqueue(ledger, url, cardSHA, key: "D.RAF")
            let h = try FileHandle(forUpdating: url); try h.seek(toOffset: UInt64(bytes / 2)); try h.write(contentsOf: Data([0x5A])); try h.close()
            let summary = await worker(ledger).runUntilIdle()
            #expect(summary.failed == 1)
            let r = try record(ledger)
            #expect(r.state == .failed && r.lastError?.contains("no longer matches the card hash") == true)
            #expect(MockS3.state.withLock { $0.objects["b/backup/D.RAF"] } == nil)
            #expect(MockS3.state.withLock { $0.uploads.isEmpty })                          // multipart aborted
        }

        @Test func refusedKeyFailsPermanentlyAndDuplicatesAreNotQueued() async throws {
            defer { try? FileManager.default.removeItem(at: tmp) }
            let ledger = try setUp()
            let (url, sha) = try localFile("E.JPG", bytes: 1000)
            try enqueue(ledger, url, sha, key: "E.JPG")
            #expect(try ledger.enqueueUpload(job: nil, relativePath: "x", localPath: url.path, sha256: sha, size: 1000,
                                             remote: RemoteDestination(destinationID: "b2", target: target, key: "backup/E.JPG")) == false)
            MockS3.state.withLock { $0.rejectAuth = true }
            let summary = await worker(ledger).runUntilIdle()
            #expect(summary.failed == 1)
            #expect(try record(ledger).lastError?.contains("refused the key") == true)
            MockS3.state.withLock { $0.rejectAuth = false }
            #expect(try ledger.retryFailedUploads() == 1)
            #expect(await worker(ledger).runUntilIdle().done == 1)
        }
    }

    @Suite struct OffsiteWorkflowTests {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-offsite-\(UUID().uuidString)")

        func workflow() -> Workflow {
            var w = Workflow.starter(root: tmp.appendingPathComponent("lib").path)
            w.destinations.append(.init(id: "b2", name: "B2", root: "",
                                        s3: S3Target(host: "mock.s3.test", bucket: "b", prefix: "photos", keyID: "k")))
            for i in w.routes.indices { w.routes[i].destinations.append("b2") }
            return w
        }

        @Test func bucketOnlyRouteIsRejected() {
            var w = workflow()
            w.routes[0].destinations = ["b2"]
            #expect { try Planner.validate(w) } throws: { e in
                guard case WorkflowError.invalid(let p) = e else { return false }
                return p.contains { $0.contains("only uploads to a bucket") }
            }
        }

        @Test func cardJobQueuesUploadsThatLandOffsiteAndPendingUploadsResume() async throws {
            defer { try? FileManager.default.removeItem(at: tmp) }
            MockS3.reset()
            let card = tmp.appendingPathComponent("card/DCIM/100A")
            try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
            for n in ["A.DNG", "A.JPG"] { try Data(repeating: n == "A.DNG" ? 1 : 2, count: 120_000).write(to: card.appendingPathComponent(n)) }
            let ledger = try Ledger(url: tmp.appendingPathComponent("ledger.sqlite"))
            let planner = try Planner(workflow())
            let files = try CardScanner().scan(tmp.appendingPathComponent("card"))

            let plan = await planner.plan(files, cardLabel: nil, ledger: ledger)
            let job = plan.job(source: JobSource(root: tmp))
            #expect(job.destinationRoots.count == 1)                                       // the bucket isn't a local root
            #expect(job.requests.allSatisfy { $0.remote.first?.key.hasPrefix("photos/") == true })
            var notices: [String] = []
            for await e in JobExecutor(ledger: ledger).run(job) { if case .notice(let n) = e { notices.append(n) } }
            #expect(notices.contains("uploads: 2 queued for offsite backup"))

            // Re-inserted before uploading: nothing to copy, but the uploads are pending and the plan can run.
            let again = await planner.plan(files, cardLabel: nil, ledger: ledger)
            #expect(again.entries.isEmpty && again.pendingUploads.count == 2 && again.canRun)

            let w = UploadWorker(ledger: ledger, secret: { _ in "s" }, session: MockS3.session)
            #expect(await w.runUntilIdle().done == 2)
            for f in files {
                let stored = MockS3.state.withLock { s in s.objects.first { $0.key.hasSuffix(f.fileName) }?.value }
                #expect(stored == (try Data(contentsOf: f.url)))
            }
            let after = await planner.plan(files, cardLabel: nil, ledger: ledger)
            #expect(after.pendingUploads.isEmpty && !after.canRun)
        }
    }
}
