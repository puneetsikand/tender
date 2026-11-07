import Foundation
import Testing
@testable import PhotoFerryCore

/// Mounts a real exFAT disk image, so DiskArbitration sees an actual removable volume.
@Suite(.serialized) struct VolumeMonitorTests {
    @discardableResult
    static func hdiutil(_ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown, userInfo: ["hdiutil": args]) }
        return text
    }

    @Test(.timeLimit(.minutes(1)))
    func reportsCardMountAndUnmount() async throws {
        let label = "PFTEST\(Int.random(in: 1000...9999))"
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).dmg")
        defer { try? FileManager.default.removeItem(at: dmg) }
        try Self.hdiutil("create", "-quiet", "-size", "8m", "-fs", "ExFAT", "-volname", label, dmg.path)

        var events = VolumeMonitor.events().makeAsyncIterator()
        try Self.hdiutil("attach", "-quiet", "-nobrowse", dmg.path)
        var mounted: VolumeInfo?
        while mounted == nil, let e = await events.next() {
            if case .mounted(let v) = e, v.name == label { mounted = v }
        }
        let v = try #require(mounted)
        #expect(v.fileSystem == "exfat")
        #expect(v.isEjectable)
        #expect(v.volumeUUID != nil)
        let mountPoint = try #require(v.mountPoint)
        #expect(VolumeMonitor.describe(mountPoint: mountPoint)?.id == v.id)

        try FileManager.default.createDirectory(at: mountPoint.appendingPathComponent("DCIM/100TEST"),
                                                withIntermediateDirectories: true)
        #expect(CardScanner().looksLikeCard(mountPoint))

        try Self.hdiutil("detach", "-quiet", mountPoint.path)
        var unmounted = false
        while !unmounted, let e = await events.next() {
            if case .unmounted(let id) = e, id == v.id { unmounted = true }
        }
        #expect(unmounted)
    }
}
