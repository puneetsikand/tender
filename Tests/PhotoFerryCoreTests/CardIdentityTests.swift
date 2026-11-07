import Foundation
import Testing
@testable import PhotoFerryCore

@Suite struct CardIdentityTests {
    /// Exactly what AppleSDXCSlot published for a SanDisk 32 GB card on 2026-11-07.
    let observed: [String: Any] = [
        "Application ID": 21316, "Block Count": 62333952, "CSD Protect Enabled": 0, "Card Type": "SDHC",
        "Manufacturer ID": 3, "Manufacturing Date": "2019-06", "Product Name": "SK32G",
        "Product Revision Level": "8.5", "Serial Number": 1233439060,
    ]

    @Test func parsesObservedCID() throws {
        let id = try #require(CardHardwareID(cardCharacteristics: observed))
        #expect(id.key == "sd:03-5344-SK32G-8.5-4984c954")   // serial matches System Information 0x4984c954
        #expect(id.oemString == "SD")
        #expect(id.manufacturingDate == "2019-06")
        #expect(id.cardType == "SDHC")
    }

    @Test func missingCoreFieldsIsNil() {
        var d = observed
        d["Serial Number"] = nil
        #expect(CardHardwareID(cardCharacteristics: d) == nil)
    }

    @Test func diskImageHasNoHardwareID() async throws {
        let label = "PFID\(Int.random(in: 1000...9999))"
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).dmg")
        defer { try? FileManager.default.removeItem(at: dmg) }
        try VolumeMonitorTests.hdiutil("create", "-quiet", "-size", "8m", "-fs", "ExFAT", "-volname", label, dmg.path)
        try VolumeMonitorTests.hdiutil("attach", "-quiet", "-nobrowse", "-mountpoint",
                                       FileManager.default.temporaryDirectory.appendingPathComponent(label).path, dmg.path)
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent(label)
        defer { _ = try? VolumeMonitorTests.hdiutil("detach", "-quiet", mount.path) }
        #expect(CardIdentity.hardwareID(forMountPoint: mount) == nil)
    }
}
