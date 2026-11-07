import Foundation

/// One file found on a source (card, mass-storage camera, or any folder).
public struct SourceFile: Sendable, Hashable, Codable {
    /// Absolute location on the source.
    public let url: URL
    /// Path relative to the source root, e.g. `DCIM/100EOSR5/IMG_0001.CR3`.
    public let relativePath: String
    public let size: Int64
    public let modificationDate: Date?
    public let kind: MediaKind

    public init(url: URL, relativePath: String, size: Int64, modificationDate: Date?, kind: MediaKind) {
        self.url = url
        self.relativePath = relativePath
        self.size = size
        self.modificationDate = modificationDate
        self.kind = kind
    }

    public var fileName: String { url.lastPathComponent }
    public var stem: String { url.deletingPathExtension().lastPathComponent }
    public var directory: String { (relativePath as NSString).deletingLastPathComponent }
}
