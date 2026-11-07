import AppKit
import IngestUI
import SwiftUI

@main
struct PhotoFerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = DeviceStore()

    var body: some Scene {
        WindowGroup("PhotoFerry") {
            IngestRootView(store: store)
                .frame(minWidth: 860, minHeight: 520)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` launches a bare executable; make it a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            NSApplication.shared.windows.forEach { $0.orderOut(nil) }
            Task { @MainActor in
                do {
                    try await DevSnapshots.run(outputDir: URL(fileURLWithPath: args[i + 1]))
                } catch {
                    FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
