import Foundation

/// Writes a checksum manifest into each destination root after a job (PLAN §5).
///
/// Format: `sha256sum`/`shasum -a 256` text format (`<hex>  <path>`), paths relative to the
/// root, so a copy can be re-checked independently with stock tools:
///     cd <root> && shasum -a 256 -c .photoferry/manifests/<file>.sha256
/// ASC MHL v2 (which also allows sha256) can be added later; this format needs no tooling.
public enum ManifestWriter {
    public static let folder = ".photoferry/manifests"

    /// Returns the manifest written per root (roots with no verified copies get none).
    @discardableResult
    public static func write(job: CopyJob, summary: CopySummary, finishedAt: Date = .now) throws -> [URL: URL] {
        let stamp = finishedAt.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: false).timeSeparator(.omitted)
            .dateSeparator(.omitted))
        let name = "\(stamp)-\(job.id.uuidString.prefix(8).lowercased()).sha256"
        var written: [URL: URL] = [:]

        for root in job.destinationRoots {
            let base = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
            var lines: [String] = []
            for result in summary.results {
                guard let hash = result.sourceSHA256 else { continue }
                for case let .written(url, _) in result.destinations {
                    let path = url.standardizedFileURL.path
                    guard path.hasPrefix(base), !path.contains("\n") else { continue }
                    lines.append("\(hash)  \(path.dropFirst(base.count))")
                }
            }
            guard !lines.isEmpty else { continue }
            let dir = root.appending(path: folder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appending(path: name)
            try Data((lines.sorted().joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
            written[root] = file
        }
        return written
    }
}
