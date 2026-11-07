import PhotoFerryCore
import SwiftUI

struct CardDetailView: View {
    let session: CardSession
    let library: WorkflowLibrary
    @State private var showingStarter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let job = session.job {
                JobProgressView(job: job)
            } else {
                planArea
            }
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
                    Label(importTitle, systemImage: "square.and.arrow.down")
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

    private var importTitle: String {
        guard let plan = session.plan else { return "Import" }
        return "Import \(plan.entries.count) Files"
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
                Button("New Starter Workflow…") { showingStarter = true }.buttonStyle(.link).controlSize(.small)
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
                TableColumn("Goes to") { r in
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
                Text("\(plan.skipped.count) file(s) stay on the card").font(.callout).foregroundStyle(.secondary)
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
