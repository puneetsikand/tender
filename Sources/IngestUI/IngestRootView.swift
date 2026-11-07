import SwiftUI
import PhotoFerryCore

/// Top-level ingest view. Placeholder until M5 (device sidebar + job queue).
public struct IngestRootView: View {
    public init() {}

    public var body: some View {
        NavigationSplitView {
            List {
                Section("Devices") {
                    Text("No cards or cameras").foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ContentUnavailableView("Insert a card or connect a camera",
                                   systemImage: "sdcard",
                                   description: Text("PhotoFerry \(PhotoFerryCore.version)"))
        }
    }
}
