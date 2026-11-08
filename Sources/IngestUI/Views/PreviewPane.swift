import PhotoFerryCore
import PhotoPreview
import SwiftUI

/// One loader for the app: its cache is shared by every card.
let previewLoader = PreviewLoader()

/// Shows the selected file (or its RAW/SOOC partner, per the two-way switch) with its camera,
/// exposure and what this copy will do with it. ← → step through files of the chosen type.
struct PreviewPane: View {
    @Bindable var session: CardSession
    @State private var preview: PreviewImage?
    @State private var loadedPath: String?
    @State private var loading = false

    var body: some View {
        let nav = session.previewNavigator
        let shown = nav.shown(for: session.selectedPath, mode: session.previewMode)
        VStack(spacing: 0) {
            toolbar(nav, shown)
            Divider()
            imageArea(shown)
            Divider()
            infoArea(shown)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(nav, shown, -1) }
        .onKeyPress(.rightArrow) { move(nav, shown, 1) }
        .task(id: "\(shown?.relativePath ?? "")|\(session.previewMode.rawValue)") { await load(shown, nav) }
    }

    // MARK: Parts

    private func toolbar(_ nav: PreviewNavigator, _ shown: SourceFile?) -> some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $session.previewMode) {
                ForEach(PreviewMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show only RAW files, or only straight-out-of-camera JPEG/HEIF/TIFF files")
            Spacer()
            if let pos = nav.position(of: shown, mode: session.previewMode) {
                Text("\(pos.index + 1) of \(pos.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            Button { _ = move(nav, shown, -1) } label: { Image(systemName: "chevron.left") }
                .disabled(nav.step(from: shown, by: -1, mode: session.previewMode) == nil)
                .help("Previous (←)")
            Button { _ = move(nav, shown, 1) } label: { Image(systemName: "chevron.right") }
                .disabled(nav.step(from: shown, by: 1, mode: session.previewMode) == nil)
                .help("Next (→)")
        }
        .controlSize(.large)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private func imageArea(_ shown: SourceFile?) -> some View {
        ZStack {
            Color.black
            if let shown, let preview, loadedPath == shown.relativePath {
                Image(decorative: preview.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .overlay(alignment: .bottomLeading) {
                        Text(sourceLabel(preview))
                            .font(.caption2).foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(8)
                    }
            } else if shown == nil {
                Text(emptyText).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).padding()
            } else if loading {
                ProgressView().controlSize(.large).tint(.white)
            } else {
                Text("No preview for this file. Press Space for Quick Look.").foregroundStyle(.white.opacity(0.7)).padding()
            }
            if loading, preview != nil, loadedPath != shown?.relativePath {
                ProgressView().tint(.white)
            }
        }
        .frame(minHeight: 240)
    }

    private var emptyText: String {
        switch session.previewMode {
        case .raw: "No RAW files here. Switch to SOOC only to see the JPEGs."
        case .sooc: "No JPEG/HEIF files here. Switch to RAW only to see the RAW files."
        }
    }

    @ViewBuilder private func infoArea(_ shown: SourceFile?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let shown {
                HStack {
                    Text(shown.fileName).font(.headline)
                    if shown.relativePath != session.selectedPath, let sel = session.selectedPath {
                        Text("(partner of \((sel as NSString).lastPathComponent))").foregroundStyle(.secondary)
                    }
                }
                if let row = session.fileList.folders.lazy.flatMap(\.rows).first(where: { $0.file == shown }) {
                    Text(statusText(row.status)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                if let info = (loadedPath == shown.relativePath ? preview?.info : nil) {
                    let line1 = [info.camera, info.lens].compactMap { $0 }.joined(separator: " · ")
                    if !line1.isEmpty { Text(line1) }
                    if let exp = info.exposure { Text(exp).monospacedDigit() }
                    HStack(spacing: 12) {
                        if let c = info.captured { Text(c) }
                        if let mp = info.megapixels { Text(mp) }
                        Text(Fmt.bytes(shown.size))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(12)
    }

    private func statusText(_ s: CardFileList.Status) -> String {
        switch s {
        case .toCopy(let p): "Will be copied to \(p)"
        case .alreadyCopied(let p): "Already copied to \(p)"
        case .notCopied(let why): "Not copied: \(why)"
        case .excluded: "Unticked for this copy"
        case .settling: "Still being written to the card"
        case .outsideNotIncluded: "Outside DCIM, not included"
        case .pending: "Choose a workflow to see where it goes"
        }
    }

    private func sourceLabel(_ p: PreviewImage) -> String {
        let ms = Int((Double(p.decodeTime.components.attoseconds) / 1e15) + Double(p.decodeTime.components.seconds) * 1000)
        let what = p.source == .embeddedPreview ? "embedded preview" : "decoded"
        return "\(what) \(p.image.width)×\(p.image.height) · \(ms) ms"
    }

    // MARK: Actions

    private func move(_ nav: PreviewNavigator, _ shown: SourceFile?, _ delta: Int) -> KeyPress.Result {
        guard let next = nav.step(from: shown, by: delta, mode: session.previewMode) else { return .ignored }
        session.selectedPath = next.relativePath
        return .handled
    }

    private func load(_ shown: SourceFile?, _ nav: PreviewNavigator) async {
        guard let shown else { preview = nil; loadedPath = nil; return }
        loading = true
        let result = await previewLoader.preview(for: shown.url, isRaw: shown.kind == .raw)
        guard !Task.isCancelled else { return }
        preview = result
        loadedPath = shown.relativePath
        loading = false
        // Look ahead (not while copying: the card's bandwidth belongs to the copy).
        guard session.job?.isRunning != true else { return }
        let ahead = [1, 2, -1].compactMap { nav.step(from: shown, by: $0, mode: session.previewMode) }
        await previewLoader.prefetch(ahead.map { ($0.url, $0.kind == .raw) })
    }
}
