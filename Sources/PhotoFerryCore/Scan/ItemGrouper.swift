import Foundation

/// Related files that must share a name and a fate: a RAW+JPEG pair, a clip with its sidecars.
public struct MediaItem: Sendable, Hashable, Codable, Identifiable {
    /// `<directory>/<normalized stem>`, stable across scans of the same card.
    public let id: String
    /// The file that represents the item (RAW over video over HEIF over JPEG …).
    public let primary: SourceFile
    /// All files in the item, primary first.
    public let members: [SourceFile]

    public var totalSize: Int64 { members.reduce(0) { $0 + $1.size } }
}

/// Groups scanned files into `MediaItem`s.
///
/// Files group when they sit in the same folder and share a stem, case-insensitively.
/// Two camera naming schemes need help:
/// - Sony clip metadata is `C0001M01.XML` next to `C0001.MP4`.
/// - GoPro uses a different prefix per file: `GX010001.MP4`, `GL010001.LRF` (and `GH…` on
///   older bodies). The THM shares the MP4's stem.
public struct ItemGrouper: Sendable {
    public init() {}

    public func group(_ files: [SourceFile]) -> [MediaItem] {
        var buckets: [String: [SourceFile]] = [:]
        for file in files {
            buckets["\(file.directory)/\(Self.groupStem(for: file))", default: []].append(file)
        }
        return buckets.map { key, members in
            let ordered = members.sorted {
                (Self.priority($0.kind), $0.fileName) < (Self.priority($1.kind), $1.fileName)
            }
            return MediaItem(id: key, primary: ordered[0], members: ordered)
        }
        .sorted { $0.id < $1.id }
    }

    static func groupStem(for file: SourceFile) -> String {
        let stem = file.stem.uppercased()
        if file.kind == .sidecar, file.url.pathExtension.lowercased() == "xml",
           let m = stem.wholeMatch(of: /(.+)M\d{2}/) {
            return String(m.1)
        }
        if let m = stem.wholeMatch(of: /G[HXL](\d{6})/) {
            return "GOPRO\(m.1)"
        }
        return stem
    }

    static func priority(_ kind: MediaKind) -> Int {
        switch kind {
        case .raw: 0
        case .video: 1
        case .heif: 2
        case .jpeg: 3
        case .tiff: 4
        case .other: 5
        case .sidecar: 6
        }
    }
}
