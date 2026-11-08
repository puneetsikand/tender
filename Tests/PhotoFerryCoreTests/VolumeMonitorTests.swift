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

    /// Detach, retrying: another process (e.g. a running PhotoFerry, which treats any volume with
    /// DCIM as a card and reads it) can briefly keep the volume busy. Forces on the last try.
    static func detach(_ path: String) throws {
        for attempt in 1...4 {
            do {
                if attempt < 4 { try hdiutil("detach", "-quiet", path) } else { try hdiutil("detach", "-quiet", "-force", path) }
                return
            } catch where attempt < 4 {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func reportsCardMountAndUnmount() async throws {
        let label = "PFTEST\(Int.random(in: 1000...9999))"
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).dmg")
        defer { try? FileManager.default.removeItem(at: dmg) }
        try Self.hdiutil("create", "-quiet", "-size", "8m", "-fs", "ExFAT", "-volname", label, dmg.path)

        var events = VolumeMonitor.events().makeAsyncIterator()
        try Self.hdiutil("attach", "-quiet", "-nobrowse", dmg.path)
        defer { try? Self.hdiutil("detach", "-quiet", "-force", "/Volumes/\(label)") }   // cleanup if a check fails
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

        try Self.detach(mountPoint.path)
        var unmounted = false
        while !unmounted, let e = await events.next() {
            if case .unmounted(let id) = e, id == v.id { unmounted = true }
        }
        #expect(unmounted)
    }

    @Test(.timeLimit(.minutes(1)))
    func ejectUnmountsTheVolume() async throws {
        let label = "PFEJ\(Int.random(in: 1000...9999))"
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
        try await VolumeMonitor.eject(mountPoint: try #require(v.mountPoint))
        var gone = false
        while !gone, let e = await events.next() {
            if case .unmounted(let id) = e, id == v.id { gone = true }
        }
        #expect(gone)
        #expect(!FileManager.default.fileExists(atPath: v.mountPoint!.path))
    }
}
