import Foundation

/// Finds media files on a source by walking the folders cameras write to.
///
/// Only known media roots are walked: `DCIM/` (the DCF standard) plus the video folders some
/// cameras keep outside it. Everything else on the card (camera settings, catalogs, Sony
/// thumbnail caches) is ignored, so a thumbnail JPEG is never mistaken for a photo.
public struct CardScanner: Sendable {
    /// Relative paths of media roots, matched case-insensitively.
    public static let mediaRoots = [
        "DCIM",
        "PRIVATE/M4ROOT/CLIP",          // Sony XAVC S / XAVC HS clips
        "PRIVATE/AVCHD/BDMV/STREAM",    // AVCHD .MTS
    ]

    public init() {}

    /// True if `root` holds any known media root. This is what makes a volume a "card".
    public func looksLikeCard(_ root: URL) -> Bool {
        !resolveMediaRoots(in: root).isEmpty
    }

    /// Lists every media file under the known media roots of `root`, sorted by relative path.
    public func scan(_ root: URL) throws -> [SourceFile] {
        let root = root.standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var files: [SourceFile] = []

        for mediaRoot in resolveMediaRoots(in: root) {
            guard let walker = FileManager.default.enumerator(
                at: mediaRoot, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in walker {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                // AppleDouble files ("._IMG_0001.JPG") are hidden, but be explicit in case a
                // volume reports them otherwise.
                if url.lastPathComponent.hasPrefix("._") { continue }
                files.append(SourceFile(
                    url: url,
                    relativePath: Self.relativePath(of: url, under: root),
                    size: Int64(values.fileSize ?? 0),
                    modificationDate: values.contentModificationDate,
                    kind: MediaKind(fileExtension: url.pathExtension)
                ))
            }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// Photos and videos on the card *outside* the media roots, which `scan` deliberately leaves
    /// out (cameras only write to DCIM; anything else was put there some other way). Reported so
    /// the user knows they weren't included.
    public struct OutsideMedia: Sendable, Hashable {
        public var count = 0
        /// Top-level folders holding them; "" = the card's root.
        public var folders: [String] = []
        public var isEmpty: Bool { count == 0 }
        public init(count: Int = 0, folders: [String] = []) {
            self.count = count
            self.folders = folders
        }
    }

    /// The photos, videos and their sidecars outside the media roots, as files that can be planned
    /// if the user chooses to include them (hidden folders like the card's Trash are skipped).
    public func scanOutsideRoots(_ root: URL, limit: Int = 20_000) -> [SourceFile] {
        let root = root.standardizedFileURL
        let resolved = resolveMediaRoots(in: root).map(\.standardizedFileURL.path)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [SourceFile] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > limit { break }
            if resolved.contains(url.standardizedFileURL.path) { walker.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  !url.lastPathComponent.hasPrefix("._") else { continue }
            let kind = MediaKind(fileExtension: url.pathExtension)
            guard kind != .other else { continue }
            files.append(SourceFile(url: url, relativePath: Self.relativePath(of: url, under: root),
                                    size: Int64(v.fileSize ?? 0), modificationDate: v.contentModificationDate, kind: kind))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    public func mediaOutsideRoots(_ root: URL, limit: Int = 20_000) -> OutsideMedia {
        let root = root.standardizedFileURL
        let roots = Set(resolveMediaRoots(in: root).map(\.standardizedFileURL.path))
        let dcim = resolveMediaRoots(in: root).first.map(\.standardizedFileURL.path)
        var out = OutsideMedia()
        var folders: [String: Int] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > limit { break }
            let path = url.standardizedFileURL.path
            if roots.contains(path) || path == dcim { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            if url.lastPathComponent.hasPrefix("._") { continue }
            let kind = MediaKind(fileExtension: url.pathExtension)
            guard kind != .other && kind != .sidecar else { continue }
            out.count += 1
            let rel = Self.relativePath(of: url, under: root)
            let top = rel.contains("/") ? String(rel.split(separator: "/")[0]) : ""
            folders[top, default: 0] += 1
        }
        out.folders = folders.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        return out
    }

    /// Resolves each known media root against the real (case-varying) folder names on disk.
    func resolveMediaRoots(in root: URL) -> [URL] {
        Self.mediaRoots.compactMap { path in
            var current = root
            for component in path.split(separator: "/") {
                guard let match = Self.childDirectory(of: current, named: String(component)) else { return nil }
                current = match
            }
            return current
        }
    }

    private static func childDirectory(of dir: URL, named name: String) -> URL? {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.first { url in
            url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full
    }
}
