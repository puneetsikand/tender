import Foundation

/// Spots files that are still being written to the card, e.g. by a Finder copy (found 2026-11-08:
/// GFX files at 0 bytes and half-written while Finder was still copying them in).
///
/// Modification dates can't tell: Finder keeps the original's date, and camera clocks drift. A
/// file is "unsettled" if it's empty, or its size changed between the scan and a second look.
public enum WriteSettle {
    /// Relative paths of empty files: never complete photos, usually a copy that has just started.
    public static func empty(_ files: [SourceFile]) -> Set<String> {
        Set(files.filter { $0.size == 0 }.map(\.relativePath))
    }

    /// Relative paths whose size on disk now differs from the scanned size (or that vanished).
    public static func changedSinceScan(_ files: [SourceFile]) -> Set<String> {
        Set(files.filter { f in
            ((try? FileManager.default.attributesOfItem(atPath: f.url.path))?[.size] as? Int64) != f.size
        }.map(\.relativePath))
    }
}
