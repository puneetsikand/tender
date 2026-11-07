import DiskArbitration
import Foundation

/// A mounted volume as DiskArbitration describes it.
public struct VolumeInfo: Sendable, Hashable, Codable {
    /// Stable for as long as the volume stays attached: BSD name (`disk6s1`), or the mount
    /// path for network volumes, which have no BSD name.
    public let id: String
    public let bsdName: String?
    public let mountPoint: URL?
    public let name: String?
    /// Filesystem volume UUID. Rewritten by a format, so recognition tier V only (PLAN §3.2).
    public let volumeUUID: String?
    /// `msdos`, `exfat`, `apfs`, `smbfs` …
    public let fileSystem: String?
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isInternalDevice: Bool
    public let isNetwork: Bool
    /// Bus the device sits on: `USB`, `Secure Digital`, `PCI-Express` …
    public let deviceProtocol: String?
    public let deviceVendor: String?
    public let deviceModel: String?
    public let mediaName: String?

    init?(description d: [String: Any]) {
        let bsd = d[kDADiskDescriptionMediaBSDNameKey as String] as? String
        let path = d[kDADiskDescriptionVolumePathKey as String] as? URL
        guard let id = bsd ?? path?.path else { return nil }
        self.id = id
        bsdName = bsd
        mountPoint = path
        name = d[kDADiskDescriptionVolumeNameKey as String] as? String
        if let uuid = d[kDADiskDescriptionVolumeUUIDKey as String] {
            volumeUUID = CFUUIDCreateString(nil, (uuid as! CFUUID)) as String?
        } else {
            volumeUUID = nil
        }
        fileSystem = d[kDADiskDescriptionVolumeKindKey as String] as? String
        isRemovable = d[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
        isEjectable = d[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false
        isInternalDevice = d[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false
        isNetwork = d[kDADiskDescriptionVolumeNetworkKey as String] as? Bool ?? false
        deviceProtocol = Self.trimmed(d[kDADiskDescriptionDeviceProtocolKey as String])
        deviceVendor = Self.trimmed(d[kDADiskDescriptionDeviceVendorKey as String])
        deviceModel = Self.trimmed(d[kDADiskDescriptionDeviceModelKey as String])
        mediaName = Self.trimmed(d[kDADiskDescriptionMediaNameKey as String])
    }

    private static func trimmed(_ v: Any?) -> String? {
        (v as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
