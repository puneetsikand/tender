import Foundation

/// Deletes a job's source files from the card: the "move" half of copy-then-delete (PLAN §7).
///
/// Only after a job in which every file verified at every destination; only the files that job
/// copied; only files still inside the card root and unchanged since they were read (same size
/// and modification date); only when every copy is still in place with the right size. Callers
/// must get an explicit confirmation first; auto-run never calls this.
public enum CardCleaner {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case notAllVerified
        case emptyJob
        public var description: String {
            switch self {
            case .notAllVerified: "not every file was copied and verified, so nothing is deleted from the card"
            case .emptyJob: "the job copied nothing"
            }
        }
    }

    public struct Report: Sendable {
        public var deleted: [String] = []
        public var kept: [(path: String, reason: String)] = []
    }

    public static func deleteVerifiedSources(of summary: CopySummary, cardRoot: URL, jobID: UUID, ledger: Ledger?) throws -> Report {
        guard !summary.results.isEmpty else { throw Refusal.emptyJob }
        guard summary.allSucceeded else { throw Refusal.notAllVerified }
        let fm = FileManager.default
        let base = cardRoot.standardizedFileURL.path.hasSuffix("/") ? cardRoot.standardizedFileURL.path : cardRoot.standardizedFileURL.path + "/"
        var report = Report()

        for result in summary.results {
            let source = result.request.source
            let path = source.url.standardizedFileURL.path
            func keep(_ reason: String) { report.kept.append((source.relativePath, reason)) }

            guard path.hasPrefix(base) else { keep("outside the card"); continue }
            guard let attrs = try? fm.attributesOfItem(atPath: path) else { keep("no longer on the card"); continue }
            guard (attrs[.size] as? Int64) == source.size,
                  Ledger.sameInstant(attrs[.modificationDate] as? Date, source.modificationDate) else {
                keep("changed on the card since it was copied"); continue
            }
            let copiesInPlace = result.destinations.allSatisfy { d in
                d.isSatisfied && (try? fm.attributesOfItem(atPath: d.url.path))?[.size] as? Int64 == source.size
            }
            guard copiesInPlace else { keep("a copy is missing or changed at its destination"); continue }
            do {
                try fm.removeItem(atPath: path)
                report.deleted.append(source.relativePath)
            } catch {
                keep("could not delete: \(error.localizedDescription)")
            }
        }
        try? ledger?.recordDeletedFromSource(job: jobID, relativePaths: report.deleted)
        return report
    }
}
