import Foundation
import Testing
@testable import PhotoFerryCore

/// The XPC wire format is Codable; these round-trips catch a type that stops encoding cleanly.
@Suite struct CopyServiceProtocolTests {
    let file = SourceFile(url: URL(fileURLWithPath: "/Volumes/CARD/DCIM/100SIGMA/SDIM0199.DNG"),
                          relativePath: "DCIM/100SIGMA/SDIM0199.DNG", size: 36_535_551,
                          modificationDate: Date(timeIntervalSince1970: 1_783_000_000), kind: .raw)

    func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func startRequestRoundTrips() throws {
        let job = CopyJob(source: JobSource(root: URL(fileURLWithPath: "/Volumes/CARD"), volumeLabel: "NO NAME", cardKey: "sd:03-5344-SK32G-8.5-4984c954"),
                          destinationRoots: [URL(fileURLWithPath: "/tmp/a")],
                          requests: [CopyRequest(source: file, destinations: [URL(fileURLWithPath: "/tmp/a/x.DNG")])],
                          options: CopyOptions(chunkSize: 4 << 20, filesInFlight: 3, fullSync: false, verify: .paranoid))
        guard case let .start(back) = try roundTrip(CopyService.Request.start(job)) else { Issue.record("wrong case"); return }
        #expect(back == job)
    }

    @Test func finishedEventRoundTrips() throws {
        let result = FileCopyResult(
            request: CopyRequest(source: file, destinations: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]),
            sourceSHA256: String(repeating: "ab", count: 32), bytesRead: file.size, sourceError: nil,
            destinations: [.written(URL(fileURLWithPath: "/a"), DestinationVerification(mode: .hash, path: .device, destinationSHA256: String(repeating: "ab", count: 32))), .failed(URL(fileURLWithPath: "/b"), reason: "destination already exists")])
        let event = CopyService.Event(job: UUID(), event: .finished(CopySummary(results: [result], bytesRead: file.size, elapsed: .milliseconds(1234))))
        let back = try roundTrip(event)
        guard case .finished(let s) = back.event else { Issue.record("wrong case"); return }
        #expect(s.results == [result])
        #expect(s.elapsed == .milliseconds(1234))
        #expect(!s.allSucceeded)
    }

    @Test func outsideTheAppBundleTheRunnerIsInProcess() {
        #expect(!CopyRunners.bundledServiceAvailable)
        #expect(CopyRunners.preferred() is InProcessCopyRunner)
    }
}
