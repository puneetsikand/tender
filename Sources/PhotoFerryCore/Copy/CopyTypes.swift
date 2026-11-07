import Foundation

/// One source file and the final paths it must land at.
public struct CopyRequest: Sendable, Hashable, Codable {
    public let source: SourceFile
    /// Final destination file URLs, one per destination root. Their parent folders are created.
    public let destinations: [URL]

    public init(source: SourceFile, destinations: [URL]) {
        self.source = source
        self.destinations = destinations
    }
}

/// How each destination copy is checked before it gets its final name (PLAN §5).
public enum VerifyMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Size only. Nearly free; catches truncation, not corruption.
    case size
    /// Re-read each copy from the device and compare its SHA-256 with the source's (the default).
    case hash
    /// `hash`, plus re-read the source and require the same SHA-256 as the first read,
    /// which catches a reader or card returning different data on different reads.
    case paranoid
    /// Byte-by-byte comparison of a fresh source read against each copy. No hash involved.
    case bytes
}

/// Where the verify read of a copy came from.
public enum VerifyPath: String, Sendable, Hashable, Codable {
    /// The copy's pages were confirmed absent from the page cache (mincore) before reading.
    case device
    /// A network share: the read came through the server, whose cache we can't evict.
    case server
    /// Eviction couldn't be confirmed, so the read may have been served from memory.
    case possiblyCached
    /// Size-only verification; nothing was read.
    case notRead
}

public struct DestinationVerification: Sendable, Hashable, Codable {
    public let mode: VerifyMode
    public let path: VerifyPath
    /// SHA-256 of the copy as re-read (hash/paranoid); nil for size/bytes.
    public let destinationSHA256: String?
}

public struct CopyOptions: Sendable, Hashable, Codable {
    /// Bytes per read. Every destination gets the same chunk.
    public var chunkSize: Int
    /// Source files copied at once. SD cards are sequential devices; too many in flight thrash.
    public var filesInFlight: Int
    /// `F_FULLFSYNC` each file before renaming it into place (falls back to `fsync`).
    public var fullSync: Bool

    public var verify: VerifyMode

    public init(chunkSize: Int = 8 << 20, filesInFlight: Int = 2, fullSync: Bool = true, verify: VerifyMode = .hash) {
        self.chunkSize = chunkSize
        self.filesInFlight = filesInFlight
        self.fullSync = fullSync
        self.verify = verify
    }

    /// Defaults for a source volume, by the bus DiskArbitration reports (PLAN §4).
    public static func defaults(for volume: VolumeInfo?) -> CopyOptions {
        switch volume?.deviceProtocol {
        case "Secure Digital", "USB": CopyOptions(filesInFlight: 2)
        case "PCI-Express", "PCI", "Apple Fabric", "NVMe", "Thunderbolt": CopyOptions(filesInFlight: 4)
        default: CopyOptions(filesInFlight: 2)
        }
    }
}

public enum DestinationOutcome: Sendable, Hashable, Codable {
    /// Written, verified, and renamed to its final name.
    case written(URL, DestinationVerification)
    case failed(URL, reason: String)

    public var url: URL {
        switch self { case .written(let u, _), .failed(let u, _): u }
    }
    public var isWritten: Bool {
        if case .written = self { true } else { false }
    }
}

public struct FileCopyResult: Sendable, Hashable, Codable {
    public let request: CopyRequest
    /// SHA-256 of the bytes read from the source, or nil if the read failed.
    public let sourceSHA256: String?
    public let bytesRead: Int64
    /// Source-side failure (unreadable, unstable between reads, cancelled). When set, nothing was written.
    public let sourceError: String?
    public let destinations: [DestinationOutcome]

    /// True only if the source was read and *every* destination was written.
    /// Never true for a request without destinations.
    public var succeeded: Bool {
        sourceError == nil && !destinations.isEmpty && destinations.allSatisfy(\.isWritten)
    }
}

public enum CopyEvent: Sendable, Codable {
    case fileStarted(index: Int, SourceFile)
    case progress(index: Int, bytesDone: Int64)
    case fileFinished(index: Int, FileCopyResult)
    case finished(CopySummary)
    /// The runner lost the job before `.finished`, e.g. the copy service connection dropped.
    /// Files already reported as finished are final; any others must be treated as not copied.
    case interrupted(reason: String)
    /// Something worth telling the user that doesn't change any file's outcome
    /// (manifest written, ledger unavailable …).
    case notice(String)
}

public struct CopySummary: Sendable, Hashable, Codable {
    public let results: [FileCopyResult]
    public let bytesRead: Int64
    public let elapsed: Duration

    public var failed: [FileCopyResult] { results.filter { !$0.succeeded } }
    /// Guarded against the empty job: copying nothing is not "all succeeded".
    public var allSucceeded: Bool { !results.isEmpty && results.allSatisfy(\.succeeded) }
    public var megabytesPerSecond: Double {
        let s = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return s > 0 ? Double(bytesRead) / 1_000_000 / s : 0
    }
}
