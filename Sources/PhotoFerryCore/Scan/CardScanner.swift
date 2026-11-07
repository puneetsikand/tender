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
