import Foundation
import PhotoFerryCore

/// The preview pane's two-way switch: show RAW files only, or straight-out-of-camera files only.
public enum PreviewMode: String, CaseIterable, Sendable {
    case raw, sooc

    public var label: String { self == .raw ? "RAW only" : "SOOC only" }

    public func accepts(_ kind: MediaKind) -> Bool {
        switch self {
        case .raw: kind == .raw
        case .sooc: kind == .jpeg || kind == .heif || kind == .tiff
        }
    }
}

/// Decides which file the preview shows and how ← → move. Pure, so it's tested without a UI.
public struct PreviewNavigator: Sendable {
    /// Every file in list order.
    public let order: [SourceFile]
    /// Item each file belongs to, by relative path (RAW+JPEG pairs, sidecars).
    public let items: [String: MediaItem]

    public init(order: [SourceFile], items: [String: MediaItem]) {
        self.order = order
        self.items = items
    }

    public func candidates(_ mode: PreviewMode) -> [SourceFile] {
        order.filter { mode.accepts($0.kind) }
    }

    /// The selected file if it fits the mode; otherwise its partner that does (the JPEG of a DNG,
    /// the DNG of a JPEG, the photo of a sidecar); with nothing selected, the first that fits.
    public func shown(for selectedPath: String?, mode: PreviewMode) -> SourceFile? {
        guard let selectedPath, let selected = order.first(where: { $0.relativePath == selectedPath }) else {
            return candidates(mode).first
        }
        if mode.accepts(selected.kind) { return selected }
        return items[selected.relativePath]?.members.first { mode.accepts($0.kind) }
    }

    /// The next (+1) or previous (−1) file of the mode's type, from the one shown.
    public func step(from current: SourceFile?, by delta: Int, mode: PreviewMode) -> SourceFile? {
        let list = candidates(mode)
        guard !list.isEmpty else { return nil }
        guard let current, let i = list.firstIndex(of: current) else { return delta >= 0 ? list.first : list.last }
        return list.indices.contains(i + delta) ? list[i + delta] : nil
    }

    /// Position of a file among the mode's files, for "12 of 61".
    public func position(of file: SourceFile?, mode: PreviewMode) -> (index: Int, count: Int)? {
        let list = candidates(mode)
        guard let file, let i = list.firstIndex(of: file) else { return nil }
        return (i, list.count)
    }
}
