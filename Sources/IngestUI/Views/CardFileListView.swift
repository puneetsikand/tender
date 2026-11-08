import PhotoFerryCore
import QuickLook
import SwiftUI

/// The card's files, grouped by folder, showing what this copy will do with each. Count chips
/// filter the list; checkboxes include or exclude files and folders for this copy; folders
/// outside DCIM are offered (unticked) in their own section. Space = Quick Look.
struct CardFileListView: View {
    @Bindable var session: CardSession
    @State private var filter: CardFileList.Filter?
    @State private var expanded: Set<String> = []
    @State private var expandedInitially = false
    @State private var previewURL: URL?
    @State private var showingNotes = false

    var body: some View {
        let list = session.fileList
        VStack(spacing: 0) {
            errorStrip
            chipBar(list)
            Divider()
            List(selection: $session.selectedPath) {
                let inside = visible(list.folders.filter { !$0.isOutsideDCIM })
                let outside = visible(list.folders.filter(\.isOutsideDCIM))
                if !inside.isEmpty {
                    Section("On the card (DCIM)") { ForEach(inside) { folder($0) } }
                }
                if !outside.isEmpty {
                    Section {
                        ForEach(outside) { folder($0) }
                    } header: {
                        Text("Outside DCIM: not written by a camera, not included unless you tick them")
                    }
                }
            }
            .quickLookPreview($previewURL, in: list.folders.flatMap { $0.rows.map(\.file.url) })
            .onKeyPress(.space) {
                guard let id = session.selectedPath, let row = list.folders.lazy.flatMap(\.rows).first(where: { $0.id == id }) else { return .ignored }
                previewURL = row.file.url
                return .handled
            }
            .onAppear { expandInitially(list) }
            .onChange(of: session.plan?.entries.count) { expandInitially(list) }
        }
    }

    // MARK: Header strips

    /// Real problems only (e.g. two files would get the same name). Everything else is a chip or a note.
    @ViewBuilder private var errorStrip: some View {
        let errors = session.plan?.issues.filter { $0.severity == .error && $0.topic != .nothingToCopy } ?? []
        if !errors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(errors, id: \.self) { Label($0.message, systemImage: "xmark.octagon.fill") }
            }
            .font(.callout).foregroundStyle(.red)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
        }
    }

    private func chipBar(_ list: CardFileList) -> some View {
        HStack(spacing: 8) {
            chip(.toCopy, list.count(.toCopy), "to copy", .accentColor)
            chip(.alreadyCopied, list.count(.alreadyCopied), "already copied", .green)
            chip(.notCopied, list.count(.notCopied), "not copied", .orange)
            chip(.outsideDCIM, list.count(.outsideDCIM), "outside DCIM", .purple)
            if session.plan == nil {
                Text(session.planning ? "Planning…" : "Choose a workflow to see where files go").foregroundStyle(.secondary)
            }
            Spacer()
            let notes = notes
            if !notes.isEmpty {
                Button { showingNotes.toggle() } label: {
                    Label("\(notes.count) note\(notes.count == 1 ? "" : "s")", systemImage: "info.circle")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showingNotes, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes, id: \.self) { n in
                            Label(n.message, systemImage: n.severity == .warning ? "exclamationmark.triangle" : "info.circle")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14).frame(width: 380)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// Issues that aren't already shown as a chip or the error strip.
    private var notes: [CopyPlan.Issue] {
        (session.plan?.issues ?? []).filter { i in
            i.severity != .error && ![.unrouted, .alreadyCopied].contains(i.topic)
        }
    }

    @ViewBuilder private func chip(_ f: CardFileList.Filter, _ n: Int, _ label: String, _ color: Color) -> some View {
        if n > 0 || f == .toCopy {
            let on = filter == f
            Button { filter = on ? nil : f } label: {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text("\(n) \(label)").monospacedDigit()
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(on ? color.opacity(0.22) : Color.secondary.opacity(0.1), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? color : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .help(on ? "Show all files" : "Show only files that are \(label)")
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    // MARK: Folders and rows

    private func visible(_ folders: [CardFileList.Folder]) -> [CardFileList.Folder] {
        guard let filter else { return folders }
        return folders.filter { $0.count(filter) > 0 }
    }

    private func rows(_ folder: CardFileList.Folder) -> [CardFileList.Row] {
        guard let filter else { return folder.rows }
        return folder.rows.filter { $0.status.filter == filter }
    }

    private func folder(_ folder: CardFileList.Folder) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(folder.id) || filter != nil },
                                            set: { if $0 { expanded.insert(folder.id) } else { expanded.remove(folder.id) } })) {
            ForEach(rows(folder)) { row in fileRow(row, folder: folder).tag(row.id) }
        } label: {
            HStack(spacing: 8) {
                checkbox(state(folder), help: folder.isOutsideDCIM ? "Include this folder in this copy" : "Include or exclude every file in this folder") {
                    session.setIncluded(folder.included < folder.rows.count, folder: folder)
                }
                Image(systemName: folder.isOutsideDCIM ? "folder.badge.questionmark" : "folder")
                    .foregroundStyle(folder.isOutsideDCIM ? .purple : .secondary)
                Text(folder.title).fontWeight(.medium)
                Text("\(folder.rows.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(folder.summary).foregroundStyle(.secondary).font(.callout)
            }
            .opacity(folder.isOutsideDCIM && folder.included == 0 ? 0.7 : 1)
        }
    }

    private func fileRow(_ row: CardFileList.Row, folder: CardFileList.Folder) -> some View {
        let locked = row.status == .outsideNotIncluded
        return HStack(spacing: 8) {
            checkbox(row.isIncluded ? .on : .off, help: locked ? "Include the folder first" : "Copy this file") {
                session.setIncluded(!row.isIncluded, file: row.file)
            }
            .disabled(locked)
            Text(row.file.fileName).lineLimit(1)
                .foregroundStyle(row.isIncluded ? .primary : .secondary)
                .frame(minWidth: 160, alignment: .leading)
            detail(row).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(Fmt.bytes(row.file.size)).foregroundStyle(.tertiary).monospacedDigit().font(.callout)
            badge(row.status)
        }
        .contextMenu {
            Button(row.isIncluded ? "Don't Copy" : "Copy") { session.setIncluded(!row.isIncluded, file: row.file) }.disabled(locked)
            Button("Quick Look") { previewURL = row.file.url }
        }
    }

    @ViewBuilder private func detail(_ row: CardFileList.Row) -> some View {
        switch row.status {
        case .toCopy(let p): Text("→ \(p)")
        case .alreadyCopied(let p): Text("→ \(p)")
        case .notCopied(let why): Text(why)
        case .excluded: Text("unticked for this copy")
        case .settling: Text("still being written to the card; it's read again when finished")
        case .outsideNotIncluded: Text("outside DCIM")
        case .pending: Text("")
        }
    }

    private func badge(_ s: CardFileList.Status) -> some View {
        let (text, color): (String, Color) = switch s {
        case .toCopy: ("new", .accentColor)
        case .alreadyCopied: ("copied", .green)
        case .notCopied: ("skipped", .orange)
        case .excluded: ("excluded", .secondary)
        case .settling: ("writing…", .orange)
        case .outsideNotIncluded: ("outside", .purple)
        case .pending: ("", .clear)
        }
        return Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
            .frame(width: 70, alignment: .trailing)
    }

    enum CheckState { case on, off, mixed }

    private func state(_ folder: CardFileList.Folder) -> CheckState {
        folder.included == 0 ? .off : folder.included == folder.rows.count ? .on : .mixed
    }

    private func checkbox(_ state: CheckState, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(state == .on ? "included" : state == .mixed ? "partly included" : "not included")
    }

    /// Open folders that have something to copy (and aren't huge) the first time.
    private func expandInitially(_ list: CardFileList) {
        guard !expandedInitially, session.plan != nil else { return }
        expandedInitially = true
        expanded = Set(list.folders.filter { $0.count(.toCopy) > 0 && $0.rows.count <= 300 }.map(\.id))
    }
}
