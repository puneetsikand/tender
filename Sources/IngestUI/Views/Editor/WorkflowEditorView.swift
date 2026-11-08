import PhotoFerryCore
import SwiftUI

/// Diagram + inspector + live preview for one workflow.
struct WorkflowEditorView: View {
    let draft: WorkflowDraft
    let library: WorkflowLibrary
    let previewCard: CardSession?
    /// Called after a save with (old name, new name), so open cards can follow a rename.
    let onSaved: (String, String) -> Void
    let onDeleted: () -> Void
    /// Saves if needed, then starts copying the preview card with this workflow.
    var onRun: (String) -> Void = { _ in }
    @State private var error: String?
    @State private var confirmingDelete = false

    var body: some View {
        HSplitView {
            VSplitView {
                ScrollView([.horizontal, .vertical]) {
                    PipelineDiagram(draft: draft)
                }
                .frame(minHeight: 260)
                PreviewPanel(draft: draft)
                    .frame(minHeight: 140, idealHeight: 220)
            }
            .frame(minWidth: 520)
            WorkflowInspector(draft: draft)
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 460)
        }
        .navigationTitle(draft.workflow.name + (draft.isDirty ? " (edited)" : ""))
        .onAppear { draft.setPreviewSource(previewCard) }
        .onChange(of: previewCard?.id) { draft.setPreviewSource(previewCard) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete Workflow", systemImage: "trash") }
                Button { draft.revert() } label: { Label("Revert", systemImage: "arrow.uturn.backward") }
                    .disabled(!draft.isDirty)
                Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down.on.square") }
                    .disabled(!draft.canSave)
                    .keyboardShortcut("s", modifiers: .command)
                Button {
                    if draft.isDirty { save() }
                    if !draft.isDirty { onRun(draft.savedName) }
                } label: {
                    Label(previewCard.map { "Run on \($0.title)" } ?? "Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(previewCard == nil || !draft.problems.isEmpty || previewCard?.job?.isRunning == true)
                .help(previewCard == nil ? "Insert a card to run this workflow" : "Save and copy the card with this workflow")
            }
        }
        .confirmationDialog("Delete “\(draft.savedName)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                do { try library.delete(draft); onDeleted() } catch { self.error = "\(error)" }
            }
        } message: {
            Text("The workflow file is removed. Files it already copied are not touched.")
        }
        .alert("Couldn't save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func save() {
        let old = draft.savedName
        do {
            let new = try library.commit(draft)
            onSaved(old, new)
        } catch {
            self.error = "\(error)"
        }
    }
}

/// Validation problems, or the plan for the inserted card.
struct PreviewPanel: View {
    let draft: WorkflowDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preview").font(.headline)
                if draft.previewing { ProgressView().controlSize(.small) }
                Spacer()
                if let plan = draft.preview {
                    Text("\(plan.entries.count) files to copy · \(plan.skipped.count) not copied")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if !draft.problems.isEmpty {
                List(draft.problems, id: \.self) { p in
                    Label(p, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            } else if draft.previewSource == nil {
                ContentUnavailableView("Insert a card to preview", systemImage: "sdcard",
                                       description: Text("The preview shows where each file on the card would go."))
            } else if let plan = draft.preview {
                PlanPreview(plan: plan)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
