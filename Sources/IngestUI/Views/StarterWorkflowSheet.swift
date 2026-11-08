import PhotoFerryCore
import SwiftUI

/// Creates the starter workflow (date, then type) in a folder the user picks.
struct StarterWorkflowSheet: View {
    let library: WorkflowLibrary
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Date, then type"
    @State private var folder: URL?
    @State private var second: URL?
    @State private var choosing = false
    @State private var choosingSecond = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Starter Workflow").font(.headline)
            Text("Files are copied into folders by date, then into RAW, JPEG and Video folders, keeping their names. Every copy is verified, and nothing on the card is changed.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name)
                LabeledContent("Folder") {
                    HStack {
                        Text(folder?.path(percentEncoded: false) ?? "None chosen").foregroundStyle(folder == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.head)
                        Button("Choose…") { choosing = true }
                    }
                }
                LabeledContent("Also copy to") {
                    HStack {
                        Text(second?.path(percentEncoded: false) ?? "Optional, e.g. a NAS").foregroundStyle(second == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.head)
                        if second != nil { Button("Clear") { second = nil } }
                        Button("Choose…") { choosingSecond = true }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folder = url }
        }
        .background(EmptyView().fileImporter(isPresented: $choosingSecond, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { second = url }
        })
    }

    private func create() {
        guard let folder else { return }
        do {
            var w = Workflow.starter(name: name, root: folder.path(percentEncoded: false))
            if let second {
                w.destinations.append(.init(id: "second", name: second.lastPathComponent, root: second.path(percentEncoded: false)))
                for i in w.routes.indices { w.routes[i].destinations.append("second") }
            }
            try library.save(w)
            created(w.name)
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
