import DiskArbitration
import Foundation
import IOKit

/// A memory card's factory identity: recognition tier H (PLAN §3.2). Survives formatting.
///
/// Source: the SD CID register, which Apple's built-in SDXC slot driver (`AppleSDXCSlot`)
/// publishes as `Card Characteristics` in the IORegistry. Confirmed 2026-11-07 on Mac17,6
/// (Genesys GL9755 PCIe SD host). USB readers generally do not expose it, and then this is nil.
public struct CardHardwareID: Sendable, Hashable, Codable {
    public let manufacturerID: Int     // CID MID (0x03 = SanDisk, 0x1B = Samsung, 0x27 = Sony/Phison …)
    public let oemID: Int              // CID OID, two ASCII characters, e.g. 0x5344 "SD"
    public let productName: String     // CID PNM, e.g. "SK32G"
    public let productRevision: String // CID PRV, e.g. "8.5"
    public let serialNumber: UInt32    // CID PSN
    public let manufacturingDate: String? // CID MDT, "YYYY-MM"
    public let cardType: String?       // "SDHC", "SDXC" …

    /// Canonical string form, stable across formats and readers that expose the CID:
    /// `sd:03-5344-SK32G-8.5-4984c954`.
    public var key: String {
        "sd:" + [String(format: "%02x", manufacturerID), String(format: "%04x", oemID), productName,
                 productRevision, String(format: "%08x", serialNumber)].joined(separator: "-")
    }

    /// OEM ID as its two ASCII characters ("SD"), when printable.
    public var oemString: String? {
        let bytes = [UInt8(truncatingIfNeeded: oemID >> 8), UInt8(truncatingIfNeeded: oemID)]
        return bytes.allSatisfy { (0x20...0x7e).contains($0) } ? String(decoding: bytes, as: UTF8.self) : nil
    }

    /// Parses the `Card Characteristics` dictionary. Returns nil without the core CID fields.
    init?(cardCharacteristics c: [String: Any]) {
        guard let mid = c["Manufacturer ID"] as? Int,
              let psn = c["Serial Number"] as? Int,
              let pnm = (c["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces), !pnm.isEmpty
        else { return nil }
        manufacturerID = mid
        oemID = c["Application ID"] as? Int ?? 0
        productName = pnm
        productRevision = c["Product Revision Level"] as? String ?? "?"
        serialNumber = UInt32(truncatingIfNeeded: psn)
        manufacturingDate = c["Manufacturing Date"] as? String
        cardType = c["Card Type"] as? String
    }
}

public enum CardIdentity {
    /// Reads the hardware ID of the card behind `mountPoint`, or nil if the reader hides it.
    public static func hardwareID(forMountPoint url: URL) -> CardHardwareID? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }

        // Search the media's ancestors (partition → whole media → … → slot) for the CID.
        let found = IORegistryEntrySearchCFProperty(
            media, kIOServicePlane, "Card Characteristics" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        guard let dict = found as? [String: Any] else { return nil }
        return CardHardwareID(cardCharacteristics: dict)
    }
}
