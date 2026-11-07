import AppKit
import SwiftUI
import IngestUI

@main
struct PhotoFerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("PhotoFerry") {
            IngestRootView()
                .frame(minWidth: 720, minHeight: 440)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` launches a bare executable; make it a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }
}
