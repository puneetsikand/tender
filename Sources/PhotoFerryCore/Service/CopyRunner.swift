import Foundation

/// Runs copy jobs: in this process, or in the bundled copy service (PLAN §8A.2).
/// The app, the CLI and a future browser app all go through this one interface.
public protocol CopyRunner: Sendable {
    var name: String { get }
    func run(_ job: CopyJob) -> AsyncStream<CopyEvent>
}

/// Runs the engine inside the calling process. Used by `swift run`, the CLI and tests,
/// and as the fallback when there is no bundled service.
public struct InProcessCopyRunner: CopyRunner {
    let ledger: Ledger?
    /// `ledger: nil` copies without recording (tests, throwaway runs).
    public init(ledger: Ledger? = try? Ledger()) {
        self.ledger = ledger
    }
    public var name: String { "in-process" }
    public func run(_ job: CopyJob) -> AsyncStream<CopyEvent> {
        JobExecutor(ledger: ledger).run(job)
    }
}

public enum CopyRunners {
    /// URL the copy service would have inside the main bundle (`Contents/XPCServices/…`).
    public static var bundledServiceURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/XPCServices/\(CopyService.name).xpc")
    }

    public static var bundledServiceAvailable: Bool {
        FileManager.default.fileExists(atPath: bundledServiceURL.path)
    }

    /// The copy service when this process is inside the app bundle, otherwise in-process.
    public static func preferred() -> any CopyRunner {
        if bundledServiceAvailable, let xpc = try? XPCCopyRunner() { return xpc }
        return InProcessCopyRunner()
    }
}
