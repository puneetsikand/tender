import Foundation

/// A complete unit of work: what to copy, where, and how. This is what a host hands to a
/// `CopyRunner`, and what the ledger records.
public struct CopyJob: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let source: JobSource
    /// Destination roots. Manifests are written per root, covering the copies under it.
    public let destinationRoots: [URL]
    public let requests: [CopyRequest]
    public let options: CopyOptions

    public init(id: UUID = UUID(), source: JobSource, destinationRoots: [URL], requests: [CopyRequest], options: CopyOptions) {
        self.id = id
        self.source = source
        self.destinationRoots = destinationRoots
        self.requests = requests
        self.options = options
    }
}

/// Where a job's files came from, with whatever identity was available (PLAN §3.2).
public struct JobSource: Sendable, Hashable, Codable {
    public let root: URL
    public let volumeLabel: String?
    public let volumeUUID: String?
    /// `CardHardwareID.key`, when the reader exposes the CID.
    public let cardKey: String?

    public init(root: URL, volumeLabel: String? = nil, volumeUUID: String? = nil, cardKey: String? = nil) {
        self.root = root
        self.volumeLabel = volumeLabel
        self.volumeUUID = volumeUUID
        self.cardKey = cardKey
    }

    /// Describes a mounted source using DiskArbitration and the card's CID, when available.
    public static func describing(_ root: URL) -> JobSource {
        let v = VolumeMonitor.describe(mountPoint: root)
        let isVolumeRoot = v?.mountPoint?.standardizedFileURL.path == root.standardizedFileURL.path
        return JobSource(root: root,
                         volumeLabel: isVolumeRoot ? v?.name : nil,
                         volumeUUID: isVolumeRoot ? v?.volumeUUID : nil,
                         cardKey: isVolumeRoot ? CardIdentity.hardwareID(forMountPoint: root)?.key : nil)
    }
}
