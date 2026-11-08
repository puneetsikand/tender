import PhotoFerryCore
import SwiftUI

/// The ingest window: devices on the left, the selected card (or history) on the right.
public struct IngestRootView: View {
    let store: DeviceStore
    @State private var selection: SidebarItem?

    public init(store: DeviceStore) {
        self.store = store
    }

    init(store: DeviceStore, initialSelection: SidebarItem?) {
        self.store = store
        _selection = State(initialValue: initialSelection)
    }

    enum SidebarItem: Hashable {
        case card(String)
        case camera(String)
        case workflow(String)
        case history
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(store: store, selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            switch selection {
            case .card(let id):
                if let session = store.cards.first(where: { $0.id == id }) {
                    CardDetailView(session: session, library: store.library) { name in selection = .workflow(name) }
                } else {
                    ContentUnavailableView("Card removed", systemImage: "sdcard")
                }
            case .camera(let id):
                CameraDetailView(camera: store.cameras.first { $0.id == id })
            case .workflow(let name):
                if let draft = store.library.draft(for: name) {
                    WorkflowEditorView(draft: draft, library: store.library, previewCard: previewCard,
                                       onSaved: { old, new in workflowSaved(old: old, new: new) },
                                       onDeleted: { selection = nil },
                                       onRun: { name in run(workflow: name) })
                        .id(name)
                } else {
                    ContentUnavailableView("Workflow not found", systemImage: "arrow.triangle.branch")
                }
            case .history:
                HistoryView(history: store.history)
            case nil:
                ContentUnavailableView("Insert a card", systemImage: "sdcard",
                                       description: Text("Cards and cameras appear in the sidebar as soon as they're connected."))
            }
        }
        .task { store.start() }
        .onChange(of: store.library.workflows.map(\.name)) { _, names in
            if case .workflow(let n) = selection, !names.contains(n) { selection = nil }
        }
        .onChange(of: store.cards.map(\.id)) { old, new in
            // Show a newly inserted card right away.
            if let added = new.first(where: { !old.contains($0) }) { selection = .card(added) }
        }
    }
}

extension IngestRootView {
    /// The card the editor previews against: the one most recently selected, else the first.
    var previewCard: CardSession? {
        store.cards.first { !$0.removed && !$0.scanning }
    }

    /// Runs a workflow on the preview card and shows its progress.
    func run(workflow name: String) {
        guard let card = previewCard else { return }
        selection = .card(card.id)
        Task {
            card.workflowName = name
            await card.replan()
            card.startImport()
        }
    }

    /// Keeps the sidebar and open cards pointing at a workflow that was just saved (maybe renamed).
    func workflowSaved(old: String, new: String) {
        selection = .workflow(new)
        for card in store.cards where card.workflowName == old || card.workflowName == new {
            if card.workflowName != new { card.workflowName = new } else { Task { await card.replan() } }
        }
    }
}

struct SidebarView: View {
    let store: DeviceStore
    @Binding var selection: IngestRootView.SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Cards") {
                if store.cards.isEmpty {
                    Text("No cards").foregroundStyle(.secondary)
                }
                ForEach(store.cards) { card in
                    CardSidebarRow(session: card).tag(IngestRootView.SidebarItem.card(card.id))
                }
            }
            if !store.cameras.isEmpty {
                Section("Cameras") {
                    ForEach(store.cameras, id: \.id) { cam in
                        Label(cam.name ?? "Camera", systemImage: "camera").tag(IngestRootView.SidebarItem.camera(cam.id))
                    }
                }
            }
            Section {
                ForEach(store.library.workflows, id: \.name) { w in
                    Label(w.name, systemImage: "arrow.triangle.branch").tag(IngestRootView.SidebarItem.workflow(w.name))
                }
            } header: {
                HStack {
                    Text("Workflows")
                    Spacer()
                    Button {
                        if let name = try? store.library.createWorkflow() { selection = .workflow(name) }
                    } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New workflow")
                }
            }
            Section {
                Label("History", systemImage: "clock.arrow.circlepath").tag(IngestRootView.SidebarItem.history)
            }
        }
    }
}

struct CardSidebarRow: View {
    let session: CardSession

    var body: some View {
        HStack {
            Label(session.title, systemImage: session.removed ? "sdcard.trianglebadge.exclamationmark" : "sdcard")
            Spacer()
            if let job = session.job, job.isRunning {
                ProgressView(value: job.fraction).progressViewStyle(.circular).controlSize(.small)
            } else if let job = session.job, job.summary?.allSucceeded == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if session.job?.isRunning == false {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if !session.scanning {
                Text("\(session.files.count)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct CameraDetailView: View {
    let camera: CameraInfo?

    var body: some View {
        if let camera {
            Form {
                LabeledContent("Name", value: camera.name ?? "Unknown")
                LabeledContent("Serial", value: camera.serialNumber ?? "Not reported")
                LabeledContent("USB", value: String(format: "%04x:%04x", camera.usbVendorID, camera.usbProductID))
                Text("Importing straight from a camera over USB isn't supported yet. Use the camera's card in a reader.")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Camera disconnected", systemImage: "camera")
        }
    }
}
