import Foundation
import Testing
@testable import IngestUI
@testable import PhotoFerryCore

/// A real CardSession on a mounted FAT32 image: does it notice files added after it was read?
@MainActor @Suite(.serialized) struct CardRefreshTests {
    static func hdiutil(_ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: ["hdiutil": args]) }
    }

    @Test(.timeLimit(.minutes(1)))
    func rereadsTheCardWhenFilesAppear() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pf-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let label = "PFR\(Int.random(in: 1000...9999))"
        let dmg = tmp.appendingPathComponent("c.dmg")
        try Self.hdiutil("create", "-quiet", "-size", "64m", "-fs", "MS-DOS FAT32", "-volname", label, dmg.path)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("card"), withIntermediateDirectories: true)
        // realpath, not resolvingSymlinksInPath (which maps /private/var back to /var).
        let root = URL(fileURLWithPath: String(cString: realpath(tmp.appendingPathComponent("card").path, nil)))
        try Self.hdiutil("attach", "-quiet", "-nobrowse", "-mountpoint", root.path, dmg.path)
        try await Task.sleep(for: .milliseconds(300))
        defer { try? Self.hdiutil("detach", "-quiet", "-force", root.path) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("DCIM/100TEST"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("DCIM/100TEST/A.JPG"))

        let library = WorkflowLibrary(store: WorkflowStore(folder: tmp.appendingPathComponent("wf")))
        try library.save(Workflow.starter(root: tmp.appendingPathComponent("lib").path))
        let volume = try #require(VolumeMonitor.describe(mountPoint: root))
        let session = CardSession(volume: volume, root: root, library: library, ledger: nil) {}
        await session.scan()
        #expect(session.files.count == 1)

        try Data("b".utf8).write(to: root.appendingPathComponent("DCIM/100TEST/B.JPG"))
        let deadline = Date.now.addingTimeInterval(10)
        while session.files.count < 2 && Date.now < deadline { try await Task.sleep(for: .milliseconds(200)) }
        #expect(session.files.count == 2, "the card wasn't re-read by itself")
        #expect(session.plan?.entries.count == 2)
        session.stopWatching()
    }
}
