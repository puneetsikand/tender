import PhotoFerryCore
import SwiftUI

struct CardDetailView: View {
    let session: CardSession
    let library: WorkflowLibrary
    var editWorkflow: (String) -> Void = { _ in }
    @State private var showingStarter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let job = session.job {
                if let reason = session.autoRunReason {
                    Label(reason, systemImage: "bolt.fill")
                        .font(.callout).padding(.horizontal, 16).padding(.top, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                JobProgressView(job: job)
                CardDeletionBar(session: session)
            } else {
                planArea
            }
            Divider()
            actionBar
        }
        .navigationTitle(session.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await session.eject() }
                } label: {
                    Label("Eject", systemImage: "eject")
                }
                .disabled(session.job?.isRunning == true || session.removed)
                .help("Eject the card")

                Button {
                    session.startImport()
                } label: {
                    Label(copyTitle, systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canImport)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .sheet(isPresented: $showingStarter) {
            StarterWorkflowSheet(library: library) { name in session.workflowName = name }
        }
    }

    private var copyTitle: String {
        guard let plan = session.plan else { return "Copy" }
        return "Copy \(plan.entries.count) Files"
    }

    /// Where the copy is started: always visible at the bottom of the card page.
    private var actionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").foregroundStyle(.secondary)
            Text(destinationsSummary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button {
                Task { await session.eject() }
            } label: {
                Label("Eject", systemImage: "eject")
            }
            .controlSize(.large)
            .disabled(session.job?.isRunning == true || session.removed)
            if session.job?.isRunning == true {
                Button(role: .cancel) {
                    session.cancelImport()
                } label: {
                    Label("Cancel Copy", systemImage: "stop.fill").frame(minWidth: 140)
                }
                .controlSize(.large)
            } else {
                Button {
                    session.startImport()
                } label: {
                    Label(copyTitle, systemImage: "doc.on.doc").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!session.canImport)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var destinationsSummary: String {
        let safe = "Files are copied and verified. Nothing on the card is changed or deleted."
        guard let plan = session.plan else { return safe }
        let used = plan.workflow.destinations.filter { d in plan.entries.contains { $0.destinationIDs.contains(d.id) } }
        guard !used.isEmpty else { return safe }
        return "Copies to " + used.map(\.name).joined(separator: " and ") + ". " + safe
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "sdcard.fill").font(.system(size: 34)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.title2.weight(.semibold))
                if session.scanning {
                    Text("Reading card…").foregroundStyle(.secondary)
                } else if let error = session.scanError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("\(session.files.count) files · \(Fmt.bytes(session.totalBytes)) · \(session.volume.deviceProtocol ?? "")")
                        .foregroundStyle(.secondary)
                }
                if !session.cameras.isEmpty {
                    Text(session.cameras.joined(separator: ", ")).foregroundStyle(.secondary)
                }
                if let id = session.hardwareID {
                    Text("Card ID \(id.key)").font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                if let note = session.autoRunNote {
                    Label(note, systemImage: "bolt.slash").foregroundStyle(.secondary)
                }
                if session.removed {
                    Label("The card was removed.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let e = session.ejectError {
                    Label("Couldn't eject: \(e)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Spacer()
            workflowPicker.frame(maxWidth: 280)
        }
        .padding(16)
    }

    @ViewBuilder private var workflowPicker: some View {
        if library.workflows.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                Text("No workflows yet").foregroundStyle(.secondary)
                Button("Create Starter Workflow…") { showingStarter = true }
            }
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                Picker("Workflow", selection: Binding(get: { session.workflowName }, set: { session.workflowName = $0 })) {
                    ForEach(library.workflows, id: \.name) { w in Text(w.name).tag(Optional(w.name)) }
                }
                HStack(spacing: 12) {
                    if let name = session.workflowName {
                        Button("Edit…") { editWorkflow(name) }
                    }
                    Button("New Starter Workflow…") { showingStarter = true }
                }
                .buttonStyle(.link).controlSize(.small)
            }
        }
    }

    @ViewBuilder private var planArea: some View {
        if session.scanning || session.planning {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = session.planError {
            ContentUnavailableView("Workflow problem", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let plan = session.plan {
            PlanPreview(plan: plan)
        } else {
            ContentUnavailableView("Choose a workflow", systemImage: "arrow.triangle.branch",
                                   description: Text("A workflow decides where each file goes and how it's named."))
        }
    }
}

/// The plan as a table: every file, where it goes. Issues on top.
struct PlanPreview: View {
    let plan: CopyPlan

    struct Row: Identifiable {
        let id: Int
        let entry: CopyPlan.Entry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !plan.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.issues, id: \.self) { issue in
                        Label(issue.message, systemImage: icon(issue.severity))
                            .foregroundStyle(color(issue.severity))
                            .font(.callout)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
            }
            Table(plan.entries.enumerated().map { Row(id: $0.offset, entry: $0.element) }) {
                TableColumn("On card") { r in Text(r.entry.file.fileName) }
                    .width(min: 120, ideal: 160)
                TableColumn("Copied to") { r in
                    Text(r.entry.relativePath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                TableColumn("Destination") { r in
                    Text(r.entry.destinationIDs.compactMap { id in plan.workflow.destinations.first { $0.id == id }?.name }.joined(separator: ", "))
                }
                .width(min: 90, ideal: 130)
                TableColumn("Size") { r in Text(Fmt.bytes(r.entry.file.size)).monospacedDigit() }
                    .width(min: 60, ideal: 80)
            }
            if !plan.skipped.isEmpty {
                Divider()
                Text("\(plan.skipped.count) file(s) not copied").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    func icon(_ s: CopyPlan.Issue.Severity) -> String {
        switch s { case .error: "xmark.octagon.fill"; case .warning: "exclamationmark.triangle.fill"; case .info: "info.circle" }
    }

    func color(_ s: CopyPlan.Issue.Severity) -> Color {
        switch s { case .error: .red; case .warning: .orange; case .info: .secondary }
    }
}
