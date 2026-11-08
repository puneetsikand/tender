import Foundation
import PhotoFerryCore

/// The card's files grouped by folder, each with what this copy will do with it. A pure value
/// built from the scan, the plan and the user's choices, so it can be tested without a UI.
public struct CardFileList: Sendable {
    public enum Status: Sendable, Hashable {
        case toCopy(String)              // relative path at the destinations
        case alreadyCopied(String)
        case notCopied(String)           // reason
        case excluded                    // unticked for this copy
        case settling                    // still being written to the card
        case outsideNotIncluded          // in a folder outside DCIM that isn't included
        case pending                     // no plan yet (choose a workflow)

        public var filter: Filter? {
            switch self {
            case .toCopy: .toCopy
            case .alreadyCopied: .alreadyCopied
            case .notCopied, .excluded, .settling: .notCopied
            case .outsideNotIncluded: .outsideDCIM
            case .pending: nil
            }
        }
    }

    public enum Filter: String, Sendable, CaseIterable { case toCopy, alreadyCopied, notCopied, outsideDCIM }

    public struct Row: Sendable, Identifiable, Hashable {
        public var id: String { file.relativePath }
        public let file: SourceFile
        public let status: Status
        public var isIncluded: Bool {
            switch status { case .excluded, .outsideNotIncluded: false; default: true }
        }
    }

    public struct Folder: Sendable, Identifiable, Hashable {
        /// Relative folder path on the card; "" is the card's top level.
        public let id: String
        public let isOutsideDCIM: Bool
        public let rows: [Row]

        public var title: String {
            if id.isEmpty { return "Card (top level)" }
            if id.caseInsensitiveCompare("DCIM") == .orderedSame { return "DCIM (top level)" }
            return id
        }
        public var included: Int { rows.count { $0.isIncluded } }
        public func count(_ f: Filter) -> Int { rows.count { $0.status.filter == f } }

        /// "12 to copy · 3 not copied", or "all already copied".
        public var summary: String {
            if isOutsideDCIM && included == 0 { return "not included" }
            let parts: [(Filter, String)] = [(.toCopy, "to copy"), (.alreadyCopied, "already copied"), (.notCopied, "not copied")]
            let present = parts.compactMap { f, label -> String? in let n = count(f); return n > 0 ? "\(n) \(label)" : nil }
            if present.count == 1, count(.alreadyCopied) == rows.count { return "all already copied" }
            return present.joined(separator: " · ")
        }
    }

    public let folders: [Folder]

    /// Folder key of a file: its directory on the card ("" for the top level).
    public static func folderKey(of file: SourceFile) -> String { file.directory }

    public init(files: [SourceFile], outside: [SourceFile], plan: CopyPlan?, excluded: Set<String>, includedOutside: Set<String>,
                settling: Set<String> = []) {
        var status: [String: Status] = [:]
        if let plan {
            for e in plan.entries { status[e.file.relativePath] = .toCopy(e.relativePath) }
            for e in plan.alreadyCopied { status[e.file.relativePath] = .alreadyCopied(e.relativePath) }
            for f in plan.skipped { status[f.relativePath] = .notCopied(plan.notCopiedReasons[f.relativePath] ?? "not copied") }
        }
        func row(_ f: SourceFile, outside: Bool) -> Row {
            if settling.contains(f.relativePath) { return Row(file: f, status: .settling) }
            if excluded.contains(f.relativePath) { return Row(file: f, status: .excluded) }
            if outside && !includedOutside.contains(Self.folderKey(of: f)) { return Row(file: f, status: .outsideNotIncluded) }
            return Row(file: f, status: status[f.relativePath] ?? .pending)
        }
        let inside = Dictionary(grouping: files, by: Self.folderKey).map { key, fs in
            Folder(id: key, isOutsideDCIM: false, rows: fs.map { row($0, outside: false) })
        }
        let out = Dictionary(grouping: outside, by: Self.folderKey).map { key, fs in
            Folder(id: key, isOutsideDCIM: true, rows: fs.map { row($0, outside: true) })
        }
        // Folders with something to copy first, then the rest; outside-DCIM folders last.
        folders = inside.sorted { ($0.count(.toCopy) == 0 ? 1 : 0, $0.id) < ($1.count(.toCopy) == 0 ? 1 : 0, $1.id) }
            + out.sorted { $0.id < $1.id }
    }

    public func count(_ f: Filter) -> Int { folders.reduce(0) { $0 + $1.count(f) } }
}
