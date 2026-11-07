/// What a file on a card is, decided by its extension. This drives the "sort RAW and other
/// formats into separate folders" routing (PLAN §8.1) and item grouping (§3.1).
public enum MediaKind: String, Sendable, Codable, CaseIterable {
    case raw
    case jpeg
    case heif
    case tiff
    case video
    /// Files that belong to another file: XMP, THM, clip XML, LRF proxies, WAV voice memos.
    case sidecar
    case other

    /// Classifies a file extension, ignoring case and any leading dot.
    public init(fileExtension: String) {
        let ext = fileExtension.lowercased().trimmingPrefix(".")
        self = Self.table[String(ext)] ?? .other
    }

    private static let table: [String: MediaKind] = {
        var t: [String: MediaKind] = [:]
        let groups: [(MediaKind, [String])] = [
            (.raw, ["cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2",
                    "pef", "dng", "3fr", "fff", "iiq", "x3f", "rwl", "srw", "erf", "mef", "mos", "kdc"]),
            (.jpeg, ["jpg", "jpeg"]),
            (.heif, ["heic", "heif", "hif"]),
            (.tiff, ["tif", "tiff"]),
            (.video, ["mov", "mp4", "m4v", "mxf", "avi", "mts", "m2ts", "braw", "r3d", "crm"]),
            (.sidecar, ["xmp", "thm", "xml", "lrf", "wav", "srt"]),
        ]
        for (kind, exts) in groups { for e in exts { t[e] = kind } }
        return t
    }()
}
