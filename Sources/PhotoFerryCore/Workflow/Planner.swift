import Foundation

/// Where every file of a scan goes under a workflow. The preview *is* the plan: running a job
/// executes exactly this.
public struct CopyPlan: Sendable {
    public struct Entry: Sendable, Hashable {
        public let file: SourceFile
        public let itemID: String
        public let routeID: String
        /// Path under each destination root, e.g. `2026/2026-11-06/RAW/SDIM0199.DNG`.
        public let relativePath: String
        public let destinationIDs: [String]
        public let metadata: CaptureMetadata
    }

    public struct Issue: Sendable, Hashable, CustomStringConvertible {
        public enum Severity: String, Sendable { case error, warning, info }
        /// What the issue is about, so a UI can show some as counts or filters instead of sentences.
        public enum Topic: String, Sendable { case general, nameClash, undated, timeZone, unrouted, orphanSidecars, alreadyCopied, nothingToCopy }
        public let severity: Severity
        public let message: String
        public let topic: Topic
        public init(severity: Severity, message: String, topic: Topic = .general) {
            self.severity = severity
            self.message = message
            self.topic = topic
        }
        public var description: String { "\(severity.rawValue): \(message)" }
    }

    public let workflow: Workflow
    public let entries: [Entry]
    /// Planned files the ledger shows were already copied to every planned destination and are
    /// still there (`skipPreviouslyCopied`). Not part of the job.
    public let alreadyCopied: [Entry]
    /// Files no route took, or that a `skip` route deliberately left on the card.
    public let skipped: [SourceFile]
    /// Why each skipped file isn't copied, by relative path.
    public let notCopiedReasons: [String: String]
    public let issues: [Issue]

    /// A plan with errors must not run.
    public var canRun: Bool { !entries.isEmpty && !issues.contains { $0.severity == .error } }

    /// The job that executes this plan.
    public func job(source: JobSource) -> CopyJob {
        let roots = Dictionary(uniqueKeysWithValues: workflow.destinations.map { ($0.id, $0.rootURL) })
        let used = workflow.destinations.filter { d in entries.contains { $0.destinationIDs.contains(d.id) } }
        let requests = entries.map { e in
            CopyRequest(source: e.file, destinations: e.destinationIDs.compactMap { roots[$0]?.appending(path: e.relativePath) },
                        metadata: e.metadata)
        }
        return CopyJob(source: source, destinationRoots: used.map(\.rootURL), requests: requests,
                       options: CopyOptions(verify: workflow.verify, onClash: workflow.onClash), workflowName: workflow.name)
    }
}

public enum WorkflowError: Error, Hashable, CustomStringConvertible {
    case invalid([String])
    public var description: String {
        switch self { case .invalid(let problems): "invalid workflow:\n  " + problems.joined(separator: "\n  ") }
    }
}

public struct Planner: Sendable {
    public let workflow: Workflow

    /// Validates the workflow; throws every problem found, not just the first.
    public init(_ workflow: Workflow) throws {
        try Self.validate(workflow)
        self.workflow = workflow
    }

    public static func validate(_ w: Workflow) throws {
        var problems: [String] = []
        if w.schemaVersion > Workflow.currentSchemaVersion {
            problems.append("schema version \(w.schemaVersion) is newer than this app understands (\(Workflow.currentSchemaVersion))")
        }
        if w.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("workflow has no name") }
        if let tz = w.timeZone, TimeZone(identifier: tz) == nil { problems.append("unknown time zone \"\(tz)\"") }
        if w.destinations.isEmpty { problems.append("no destinations") }
        let ids = w.destinations.map(\.id)
        for dup in Set(ids.filter { id in ids.filter { $0 == id }.count > 1 }) { problems.append("destination id \"\(dup)\" is used twice") }
        for d in w.destinations where d.root.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("destination \"\(d.id)\" has no folder") }
        if w.routes.isEmpty { problems.append("no routes") }
        let routeIDs = w.routes.map(\.id)
        for dup in Set(routeIDs.filter { id in routeIDs.filter { $0 == id }.count > 1 }) { problems.append("route id \"\(dup)\" is used twice") }
        for r in w.routes {
            if !r.skip && r.destinations.isEmpty { problems.append("route \"\(r.id)\" has no destinations (set skip to leave files on the card)") }
            for d in r.destinations where !ids.contains(d) { problems.append("route \"\(r.id)\" sends files to unknown destination \"\(d)\"") }
            for (label, text) in [("folder", r.folder), ("file name", r.fileName)] {
                do { _ = try Template(text) } catch { problems.append("route \"\(r.id)\" \(label): \(error)") }
            }
            if r.fileName.contains("/") { problems.append("route \"\(r.id)\" file name contains / (put folders in the folder template)") }
        }
        if !problems.isEmpty { throw WorkflowError.invalid(problems) }
    }

    /// Reads metadata and plans every file. `cardLabel` feeds `{card}`. With a ledger and
    /// `skipPreviouslyCopied`, files already copied to every planned destination are set aside.
    public func plan(_ files: [SourceFile], cardLabel: String?, ledger: Ledger? = nil) async -> CopyPlan {
        let zone = workflow.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let reader = MetadataReader(fallbackTimeZone: zone)
        let items = ItemGrouper().group(files)

        // Members share one set of metadata: the primary's, unless it has no capture date and
        // another member does (a dateless clip next to a dated JPEG, a RAW ImageIO can't read).
        var meta: [String: CaptureMetadata] = [:]
        for item in items {
            var best = await reader.read(item.primary)
            if best.captureDate == nil {
                for member in item.members.dropFirst() where member.kind != .sidecar {
                    let m = await reader.read(member)
                    if m.captureDate != nil { best = m; break }
                }
            }
            meta[item.id] = best
        }

        // {seq} counts items in capture order (file date when there's no capture date).
        func when(_ item: MediaItem) -> Date { meta[item.id]?.captureDate ?? item.primary.modificationDate ?? .distantPast }
        let ordered = items.sorted { (when($0), $0.id) < (when($1), $1.id) }

        let compiled = workflow.routes.map { r in
            (route: r, folder: try! Template(r.folder), name: try! Template(r.fileName))   // validated in init
        }
        let formatters = DateFormatters(defaultZone: zone)
        var entries: [CopyPlan.Entry] = []
        var skipped: [SourceFile] = []
        var unrouted: [SourceFile] = []
        var orphans: [SourceFile] = []
        var reasons: [String: String] = [:]
        var issues: [CopyPlan.Issue] = []
        var undated = 0

        for (n, item) in ordered.enumerated() {
            let m = meta[item.id] ?? CaptureMetadata()
            if m.captureDate == nil && item.primary.kind != .sidecar { undated += 1 }
            let primaryRoute = compiled.first { $0.route.match.matches(item.primary, m) }
            // Where each member of this item went, so a "NAME.EXT.xmp" sidecar can follow its file.
            var placed: [String: (route: Workflow.Route, folder: [String], name: String)] = [:]
            var owned: [SourceFile] = []
            for file in item.members {
                if ItemGrouper.ownerFileName(ofSidecar: file) != nil { owned.append(file); continue }
                // Sidecars travel with their primary unless a route names their kind explicitly.
                let explicit = compiled.first { $0.route.match.kinds?.contains(file.kind) == true && $0.route.match.matches(file, m) }
                let chosen = file.kind == .sidecar ? (explicit ?? primaryRoute) : compiled.first { $0.route.match.matches(file, m) }
                guard let chosen else {
                    unrouted.append(file); skipped.append(file)
                    reasons[file.relativePath] = "no route takes \(file.kind == .other ? "this kind of file" : file.kind.rawValue.uppercased() + " files")"
                    continue
                }
                if chosen.route.skip {
                    skipped.append(file)
                    reasons[file.relativePath] = "the “\(chosen.route.name)” route says don't copy"
                    continue
                }

                let context = Template.Context(file: file, meta: m, date: m.captureDate ?? file.modificationDate,
                                               sequence: workflow.sequenceStart + n, cardLabel: cardLabel,
                                               workflowName: workflow.name, formatters: formatters)
                var ext = file.url.pathExtension
                switch workflow.extensionCase {
                case .original: break
                case .lower: ext = ext.lowercased()
                case .upper: ext = ext.uppercased()
                }
                // A sidecar following its primary takes the primary's name, so IMG_0001.xmp stays
                // next to (and named like) its renamed RAW.
                let nameSource = file.kind == .sidecar && explicit == nil
                    ? Template.Context(file: item.primary, meta: m, date: context.date, sequence: context.sequence,
                                       cardLabel: cardLabel, workflowName: workflow.name, formatters: formatters)
                    : context
                let folder = chosen.folder.render(context).split(separator: "/").map(String.init).filter { !$0.isEmpty }
                let name = chosen.name.render(nameSource) + (ext.isEmpty ? "" : ".\(ext)")
                entries.append(CopyPlan.Entry(file: file, itemID: item.id, routeID: chosen.route.id,
                                              relativePath: (folder + [name]).joined(separator: "/"),
                                              destinationIDs: chosen.route.destinations, metadata: m))
                placed[file.fileName.lowercased()] = (chosen.route, folder, name)
            }
            // "M10_1091.DNG.xmp" goes where M10_1091.DNG went, named after it: the copied DNG's new
            // name plus ".xmp", so editing software still pairs them. No file, no sidecar.
            for file in owned {
                guard let owner = ItemGrouper.ownerFileName(ofSidecar: file),
                      let target = placed[owner.lowercased()] else {
                    orphans.append(file); skipped.append(file)
                    let owner = ItemGrouper.ownerFileName(ofSidecar: file) ?? "its photo"
                    reasons[file.relativePath] = item.members.contains { $0.fileName.caseInsensitiveCompare(owner) == .orderedSame }
                        ? "its file \(owner) isn't copied" : "its file \(owner) isn't on the card"
                    continue
                }
                let ext = file.url.pathExtension
                entries.append(CopyPlan.Entry(file: file, itemID: item.id, routeID: target.route.id,
                                              relativePath: (target.folder + ["\(target.name).\(ext)"]).joined(separator: "/"),
                                              destinationIDs: target.route.destinations, metadata: m))
            }
        }

        // Two files must never map to the same destination file. Case-insensitive, because
        // APFS and SMB shares usually are.
        var byPath: [String: [CopyPlan.Entry]] = [:]
        for e in entries { for d in e.destinationIDs { byPath["\(d)/\(e.relativePath.lowercased())", default: []].append(e) } }
        for (_, clash) in byPath.sorted(by: { $0.key < $1.key }) where clash.count > 1 {
            issues.append(.init(severity: .error, message: "\(clash.count) files would be named \(clash[0].relativePath): "
                                + clash.map(\.file.relativePath).joined(separator: ", ") + ". Add {seq} or {orig} to the file name.", topic: .nameClash))
        }
        if undated > 0 {
            issues.append(.init(severity: .warning, message: "\(undated) item(s) have no capture date; their file dates were used", topic: .undated))
        }
        if workflow.timeZone == nil, entries.contains(where: { $0.metadata.captureDate != nil && !$0.metadata.captureDateHasOffset }) {
            issues.append(.init(severity: .info, message: "capture times without a time-zone offset were read as \(zone.identifier) (the Mac's zone); set timeZone in the workflow to pin it", topic: .timeZone))
        }
        if !unrouted.isEmpty {
            issues.append(.init(severity: .warning, message: "\(unrouted.count) file(s) matched no route and won't be copied: "
                                + unrouted.prefix(5).map(\.relativePath).joined(separator: ", ") + (unrouted.count > 5 ? " …" : ""),
                                topic: .unrouted))
        }
        if !orphans.isEmpty {
            // Left out on purpose: a sidecar named after a file that isn't being copied pairs with nothing.
            issues.append(.init(severity: .info, message: "\(orphans.count) sidecar file(s) aren't copied because the file they belong to isn't on the card", topic: .orphanSidecars))
        }
        // Already copied earlier (re-inserted card, or an interrupted job): leave those out.
        // {seq} was numbered over every file first, so names stay stable across runs.
        var alreadyCopied: [CopyPlan.Entry] = []
        if workflow.skipPreviouslyCopied, let ledger, !entries.isEmpty {
            let roots = Dictionary(uniqueKeysWithValues: workflow.destinations.map { ($0.id, $0.rootURL) })
            let checks = entries.flatMap { e in e.destinationIDs.compactMap { roots[$0] }.map { (e.file, $0.appending(path: e.relativePath)) } }
            if let done = try? ledger.previouslyCopied(checks) {
                let (old, new) = entries.reduce(into: ([CopyPlan.Entry](), [CopyPlan.Entry]())) { acc, e in
                    let paths = e.destinationIDs.compactMap { roots[$0]?.appending(path: e.relativePath).path }
                    if !paths.isEmpty && paths.allSatisfy(done.contains) { acc.0.append(e) } else { acc.1.append(e) }
                }
                alreadyCopied = old
                entries = new
            }
        }
        if !alreadyCopied.isEmpty {
            issues.append(.init(severity: .info, message: entries.isEmpty
                ? "all \(alreadyCopied.count) files were already copied with this workflow and are still in place"
                : "\(alreadyCopied.count) file(s) were already copied earlier and are still in place; only the \(entries.count) new file(s) will be copied",
                topic: .alreadyCopied))
        } else if entries.isEmpty {
            issues.append(.init(severity: .error, message: "nothing to copy", topic: .nothingToCopy))
        }
        return CopyPlan(workflow: workflow, entries: entries, alreadyCopied: alreadyCopied, skipped: skipped,
                        notCopiedReasons: reasons, issues: issues)
    }
}
