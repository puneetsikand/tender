import PhotoFerryCore
import SwiftUI

/// Edits whatever is selected in the diagram.
struct WorkflowInspector: View {
    let draft: WorkflowDraft

    var body: some View {
        Form {
            switch draft.selection {
            case .settings: SettingsPane(draft: draft)
            case .route(let id):
                if draft.route(id) != nil { RoutePane(draft: draft, id: id) }
            case .destination(let id):
                if draft.destination(id) != nil { DestinationPane(draft: draft, id: id) }
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingsPane: View {
    @Bindable var draft: WorkflowDraft
    static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        Section("Workflow") {
            TextField("Name", text: $draft.workflow.name)
            Picker("Verify", selection: $draft.workflow.verify) {
                ForEach(VerifyMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Text(WorkflowDescriber.verifyText(draft.workflow.verify)).font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Picker("Time zone", selection: $draft.workflow.timeZone) {
                Text("The Mac's time zone").tag(String?.none)
                Divider()
                ForEach(Self.zones, id: \.self) { Text($0).tag(Optional($0)) }
            }
        } header: {
            Text("Capture times")
        } footer: {
            Text("Used for photos whose camera didn't record a time zone. Photos that did are filed by local time where they were taken.")
        }
        Section("Names") {
            Picker("Extensions", selection: $draft.workflow.extensionCase) {
                Text("As on card").tag(Workflow.ExtensionCase.original)
                Text("lowercase").tag(Workflow.ExtensionCase.lower)
                Text("UPPERCASE").tag(Workflow.ExtensionCase.upper)
            }
            Stepper("{seq} starts at \(draft.workflow.sequenceStart)", value: $draft.workflow.sequenceStart, in: 0...999_999)
        }
    }
}

struct RoutePane: View {
    let draft: WorkflowDraft
    let id: String

    private func bind<T>(_ key: WritableKeyPath<Workflow.Route, T>) -> Binding<T> {
        Binding(get: { draft.route(id)![keyPath: key] },
                set: { v in draft.updateRoute(id) { $0[keyPath: key] = v } })
    }

    /// Comma-separated text ↔ optional list (empty text = no condition).
    private func list(_ key: WritableKeyPath<Workflow.Match, [String]?>) -> Binding<String> {
        Binding(get: { (draft.route(id)!.match[keyPath: key] ?? []).joined(separator: ", ") },
                set: { text in
                    let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    draft.updateRoute(id) { $0.match[keyPath: key] = items.isEmpty ? nil : items }
                })
    }

    var body: some View {
        let route = draft.route(id)!
        let index = draft.workflow.routes.firstIndex { $0.id == id } ?? 0
        Section("Route \(index + 1)") {
            TextField("Name", text: bind(\.name))
            HStack {
                Button { draft.moveRoute(id, by: -1) } label: { Label("Earlier", systemImage: "arrow.up") }
                    .disabled(index == 0)
                Button { draft.moveRoute(id, by: 1) } label: { Label("Later", systemImage: "arrow.down") }
                    .disabled(index == draft.workflow.routes.count - 1)
                Spacer()
                Button(role: .destructive) { draft.removeRoute(id) } label: { Label("Delete", systemImage: "trash") }
            }
            .buttonStyle(.borderless)
        }
        Section {
            KindChips(selected: Binding(get: { route.match.kinds ?? [] },
                                        set: { k in draft.updateRoute(id) { $0.match.kinds = k.isEmpty ? nil : k } }))
            TextField("Extensions", text: list(\.extensions), prompt: Text("any, e.g. dng, cr3"))
            TextField("Camera model contains", text: list(\.cameraModels), prompt: Text("any camera"))
            TextField("Body serial", text: list(\.bodySerials), prompt: Text("any body"))
            ForEach(cameraSuggestions, id: \.serial) { cam in
                Button("Match only \(cam.model) #\(cam.serial)") {
                    draft.updateRoute(id) { $0.match.bodySerials = [cam.serial] }
                }
                .buttonStyle(.link)
            }
        } header: {
            Text("Takes files that are")
        } footer: {
            Text("All filled-in conditions must hold. Sidecars (XMP, THM …) follow their photo unless a route names their type.")
        }
        Section {
            Toggle("Don't copy these files", isOn: bind(\.skip))
            if !route.skip {
                ForEach(draft.workflow.destinations) { d in
                    Toggle(d.name, isOn: Binding(
                        get: { draft.route(id)!.destinations.contains(d.id) },
                        set: { on in draft.updateRoute(id) { r in
                            if on { if !r.destinations.contains(d.id) { r.destinations.append(d.id) } }
                            else { r.destinations.removeAll { $0 == d.id } }
                        } }))
                }
                Button {
                    let route = id
                    let new = draft.addDestination()
                    draft.updateRoute(route) { $0.destinations.append(new) }
                } label: { Label("Add Destination…", systemImage: "plus") }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Copy to")
        } footer: {
            Text(route.skip ? "These files are skipped. Nothing on the card is ever changed or deleted."
                            : "Tick every folder these files should be copied to. Each copy is verified separately.")
        }
        if !route.skip {
            Section {
                TemplateField(label: "Folder", text: bind(\.folder))
                TemplateField(label: "File name", text: bind(\.fileName))
                if let example = draft.example(forRoute: id) {
                    LabeledContent("Example", value: example).font(.callout.monospaced()).textSelection(.enabled)
                } else if draft.previewSource != nil {
                    Text("No file on the inserted card takes this route.").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Names")
            } footer: {
                Text("The original extension is added to the file name.")
            }
        }
    }

    /// Body serials seen on the inserted card, for one-click matching.
    private var cameraSuggestions: [(model: String, serial: String)] {
        guard let plan = draft.previewSource?.plan else { return [] }
        var seen = Set<String>()
        return plan.entries.compactMap { e in
            guard let s = e.metadata.bodySerial, seen.insert(s).inserted else { return nil }
            return (e.metadata.cameraModel ?? "Camera", s)
        }
    }
}

/// Toggle chips for file types.
struct KindChips: View {
    @Binding var selected: [MediaKind]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type")
            FlowLayout(spacing: 4) {
                ForEach(MediaKind.allCases.filter { $0 != .other }, id: \.self) { kind in
                    let on = selected.contains(kind)
                    let toggle = { if on { selected.removeAll { $0 == kind } } else { selected.append(kind) } }
                    // A checkmark as well as the prominent style, so selection doesn't rely on color.
                    Group {
                        if on {
                            Button(action: toggle) { Label(kind.rawValue.uppercased(), systemImage: "checkmark") }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(kind.rawValue.uppercased(), action: toggle).buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.small)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text(selected.isEmpty ? "No type selected: any type." : "").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A template text field with an "Insert token" menu and inline validation.
struct TemplateField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(label, text: $text).font(.body.monospaced())
                Menu {
                    ForEach(Template.Token.allCases, id: \.self) { token in
                        Button("{\(token.rawValue)}  \(token.help)") { text += "{\(token.rawValue)}" }
                    }
                } label: {
                    Image(systemName: "curlybraces")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Insert a token")
            }
            if let error = parseError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var parseError: String? {
        do { _ = try Template(text); return nil } catch let e as Template.ParseError { return e.message } catch { return "\(error)" }
    }
}

struct DestinationPane: View {
    let draft: WorkflowDraft
    let id: String
    @State private var choosing = false

    var body: some View {
        let d = draft.destination(id)!
        Section("Destination") {
            TextField("Name", text: Binding(get: { draft.destination(id)!.name },
                                            set: { v in draft.updateDestination(id) { $0.name = v } }))
            LabeledContent("Folder") {
                HStack {
                    Text(d.root.isEmpty ? "None chosen" : d.root).foregroundStyle(d.root.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.head)
                    Button("Choose…") { choosing = true }
                }
            }
            let users = draft.workflow.routes.filter { $0.destinations.contains(id) }.map(\.name)
            LabeledContent("Used by", value: users.isEmpty ? "No routes" : users.joined(separator: ", "))
        }
        Section {
            Button(role: .destructive) { draft.removeDestination(id) } label: { Label("Delete Destination", systemImage: "trash") }
                .disabled(draft.workflow.destinations.count == 1)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                draft.updateDestination(id) { $0.root = (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath }
            }
        }
    }
}
