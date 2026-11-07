import AppKit
import PhotoFerryCore
import SwiftUI

/// Dev tool: drives the real ingest flow against the card that's inserted and renders each
/// stage offscreen to PNG (no screen-recording permission needed). `PhotoFerry --snapshot <dir>`.
/// Point `PF_WORKFLOWS` / `PF_LEDGER` at a scratch folder first; the import goes to
/// `<dir>/library` through an in-process runner.
@MainActor
public enum DevSnapshots {
    public static func run(outputDir: URL) async throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let store = DeviceStore()
        store.start()

        let session = try await waitFor("a card", timeout: 20) { store.cards.first { !$0.scanning } }
        if store.library.workflows.isEmpty {
            try store.library.save(Workflow.starter(name: "Date, then type", root: outputDir.appending(path: "library").path))
        }
        session.workflowName = store.library.workflows.first?.name
        await session.replan()
        _ = try await waitFor("a plan", timeout: 20) { session.plan }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // Offscreen rendering doesn't draw the window background, so supply one and pin light mode.
        window.appearance = NSAppearance(named: .aqua)
        func show(_ selection: IngestRootView.SidebarItem) {
            window.contentView = NSHostingView(rootView: IngestRootView(store: store, initialSelection: selection)
                .frame(width: 1100, height: 680)
                .background(Color(nsColor: .windowBackgroundColor)))
        }
        show(.card(session.id))
        try await snap(window, outputDir.appending(path: "1-card.png"))

        session.startImport(runner: InProcessCopyRunner())
        let job = try await waitFor("the job", timeout: 5) { session.job }
        _ = try await waitFor("progress", timeout: 60) { job.fraction > 0.35 ? true : nil }
        try await snap(window, outputDir.appending(path: "2-progress.png"))
        _ = try await waitFor("the job to finish", timeout: 180) { job.isRunning ? nil : true }
        try await snap(window, outputDir.appending(path: "3-done.png"))

        store.history.reload()
        show(.history)
        try await snap(window, outputDir.appending(path: "4-history.png"))
    }

    struct Timeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting for \(what)" }
    }

    static func waitFor<T>(_ what: String, timeout: Double, _ probe: () -> T?) async throws -> T {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let v = probe() { return v }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Timeout(what: what)
    }

    static func snap(_ window: NSWindow, _ url: URL) async throws {
        try await Task.sleep(for: .milliseconds(600))   // let SwiftUI settle
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
