import Foundation

/// A saved ingest workflow (PLAN §8): where files go and how they're named, as data.
///
/// Stored as JSON (`*.pfflow`). Routes are tried in order and the first match takes the file.
/// Sidecars (XMP, THM …) follow their item's primary file unless a route matches them explicitly.
public struct Workflow: Sendable, Hashable, Codable {
    /// v2 (2026-11-08) added onClash, skipPreviouslyCopied, afterCopy, autoRun. v1 files load
    /// with those at their defaults.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var name: String
    /// IANA zone for capture times that carry no UTC offset (e.g. SIGMA fp files).
    /// Nil = the Mac's zone at run time.
    public var timeZone: String?
    public var verify: VerifyMode
    public var destinations: [Destination]
    public var routes: [Route]
    /// First value of `{seq}` in each job.
    public var sequenceStart: Int
    public var extensionCase: ExtensionCase
    /// A *different* file already has the planned name. Identical files are always skipped.
    public var onClash: ClashPolicy
    /// Leave out files the ledger shows were already copied to the same place and are still there,
    /// so a re-inserted card copies only what's new (and an interrupted copy resumes).
    public var skipPreviouslyCopied: Bool
    public var afterCopy: AfterCopy
    public var autoRun: AutoRun

    public init(name: String, timeZone: String? = nil, verify: VerifyMode = .hash, destinations: [Destination],
                routes: [Route], sequenceStart: Int = 1, extensionCase: ExtensionCase = .original,
                onClash: ClashPolicy = .keepBoth, skipPreviouslyCopied: Bool = true,
                afterCopy: AfterCopy = AfterCopy(), autoRun: AutoRun = AutoRun()) {
        schemaVersion = Self.currentSchemaVersion
        self.onClash = onClash
        self.skipPreviouslyCopied = skipPreviouslyCopied
        self.afterCopy = afterCopy
        self.autoRun = autoRun
        self.name = name
        self.timeZone = timeZone
        self.verify = verify
        self.destinations = destinations
        self.routes = routes
        self.sequenceStart = sequenceStart
        self.extensionCase = extensionCase
    }

    public struct Destination: Sendable, Hashable, Codable, Identifiable {
        /// Short stable id routes refer to, e.g. "mac", "nas".
        public var id: String
        public var name: String
        /// Folder path; `~` expands to the home folder.
        public var root: String

        public init(id: String, name: String, root: String) {
            self.id = id
            self.name = name
            self.root = root
        }

        public var rootURL: URL {
            URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        }
    }

    public struct Route: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var name: String
        public var match: Match
        /// Folder under each destination root, e.g. `{date:yyyy}/{date:yyyy-MM-dd}/{KIND}`.
        public var folder: String
        /// File name without extension, e.g. `{orig}` or `{date:yyyyMMdd}_{seq:4}`. The original
        /// extension is appended (see `extensionCase`).
        public var fileName: String
        /// Destination ids. Empty with `skip` = deliberately leave these files on the card.
        public var destinations: [String]
        public var skip: Bool

        public init(id: String, name: String, match: Match, folder: String, fileName: String = "{orig}",
                    destinations: [String], skip: Bool = false) {
            self.id = id
            self.name = name
            self.match = match
            self.folder = folder
            self.fileName = fileName
            self.destinations = destinations
            self.skip = skip
        }
    }

    /// All given conditions must hold; within a list, any value matches. An empty match takes everything.
    public struct Match: Sendable, Hashable, Codable {
        public var kinds: [MediaKind]?
        /// Case-insensitive, without the dot.
        public var extensions: [String]?
        /// Case-insensitive substring of the camera model, e.g. "fp".
        public var cameraModels: [String]?
        public var bodySerials: [String]?

        public init(kinds: [MediaKind]? = nil, extensions: [String]? = nil, cameraModels: [String]? = nil, bodySerials: [String]? = nil) {
            self.kinds = kinds
            self.extensions = extensions
            self.cameraModels = cameraModels
            self.bodySerials = bodySerials
        }

        func matches(_ file: SourceFile, _ meta: CaptureMetadata) -> Bool {
            if let kinds, !kinds.contains(file.kind) { return false }
            if let extensions, !extensions.contains(where: { $0.caseInsensitiveCompare(file.url.pathExtension) == .orderedSame }) { return false }
            if let cameraModels {
                guard let model = meta.cameraModel, cameraModels.contains(where: { model.localizedCaseInsensitiveContains($0) }) else { return false }
            }
            if let bodySerials {
                guard let serial = meta.bodySerial, bodySerials.contains(serial) else { return false }
            }
            return true
        }
    }

    public enum ExtensionCase: String, Sendable, Hashable, Codable {
        case original, lower, upper
    }

    /// Runs after a job in which every file verified at every destination.
    public struct AfterCopy: Sendable, Hashable, Codable {
        public var eject: Bool
        public var notify: Bool
        public init(eject: Bool = false, notify: Bool = true) {
            self.eject = eject
            self.notify = notify
        }
    }

    /// Start this workflow by itself when a matching card is inserted (PLAN §3.2). Matching is on
    /// the card's hardware ID or a camera body serial found on it, never on the volume name.
    /// Auto-run never deletes from the card.
    public struct AutoRun: Sendable, Hashable, Codable {
        public var cardKeys: [String]
        public var bodySerials: [String]
        public init(cardKeys: [String] = [], bodySerials: [String] = []) {
            self.cardKeys = cardKeys
            self.bodySerials = bodySerials
        }
        public var isEnabled: Bool { !cardKeys.isEmpty || !bodySerials.isEmpty }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, name, timeZone, verify, destinations, routes, sequenceStart, extensionCase
        case onClash, skipPreviouslyCopied, afterCopy, autoRun
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        name = try c.decode(String.self, forKey: .name)
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        verify = try c.decode(VerifyMode.self, forKey: .verify)
        destinations = try c.decode([Destination].self, forKey: .destinations)
        routes = try c.decode([Route].self, forKey: .routes)
        sequenceStart = try c.decode(Int.self, forKey: .sequenceStart)
        extensionCase = try c.decode(ExtensionCase.self, forKey: .extensionCase)
        // v2 fields; absent in v1 files.
        onClash = try c.decodeIfPresent(ClashPolicy.self, forKey: .onClash) ?? .keepBoth
        skipPreviouslyCopied = try c.decodeIfPresent(Bool.self, forKey: .skipPreviouslyCopied) ?? true
        afterCopy = try c.decodeIfPresent(AfterCopy.self, forKey: .afterCopy) ?? AfterCopy()
        autoRun = try c.decodeIfPresent(AutoRun.self, forKey: .autoRun) ?? AutoRun()
    }
}

extension Workflow {
    /// The starter workflow: one library folder, by date, then by file type (the layout the
    /// future browser reads). Keeps original file names.
    public static func starter(name: String = "Date, then type", root: String = "~/Pictures/PhotoFerry") -> Workflow {
        let day = "{date:yyyy}/{date:yyyy-MM-dd}"
        return Workflow(
            name: name,
            destinations: [Destination(id: "library", name: "Photo library", root: root)],
            routes: [
                Route(id: "raw", name: "RAW", match: Match(kinds: [.raw]), folder: "\(day)/RAW", destinations: ["library"]),
                Route(id: "jpeg", name: "JPEG & HEIF", match: Match(kinds: [.jpeg, .heif, .tiff]), folder: "\(day)/JPEG", destinations: ["library"]),
                Route(id: "video", name: "Video", match: Match(kinds: [.video]), folder: "\(day)/Video", destinations: ["library"]),
            ])
    }
}
