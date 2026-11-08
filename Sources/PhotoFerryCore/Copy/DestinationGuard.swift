import Darwin
import Foundation

/// Makes sure copies land on the volume each destination folder was on when the job started.
///
/// Without this, an unmounted share or drive is silently replaced by an ordinary folder on the
/// boot disk (its mount point, or `/Volumes/<name>` recreated by `mkdir -p`), and "verified"
/// copies fill the Mac's own disk instead. Found by test on 2026-11-08.
struct DestinationGuard: Sendable {
    struct Root: Sendable {
        let path: String
        /// Device the root lives on at job start; nil = unavailable from the start.
        let device: dev_t?
        let problem: String?
    }

    let roots: [Root]

    /// Resolves each root at job start, creating it only when that can't land on the wrong disk.
    init(roots: [URL]) {
        self.roots = roots.map { url in
            let path = url.standardizedFileURL.path
            if let problem = Self.unmountedVolume(path) {
                return Root(path: path, device: nil, problem: problem)
            }
            if !FileManager.default.fileExists(atPath: path) {
                do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
                catch { return Root(path: path, device: nil, problem: "destination folder \(path) can't be created: \(error.localizedDescription)") }
            }
            guard let dev = Self.device(path) else {
                return Root(path: path, device: nil, problem: "destination folder \(path) isn't available")
            }
            return Root(path: path, device: dev, problem: nil)
        }
    }

    /// Why a copy to `destination` must not be attempted now, or nil if it's safe.
    func problem(for destination: URL) -> String? {
        let path = destination.standardizedFileURL.path
        guard let root = roots.filter({ path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }) else { return nil }
        if let problem = root.problem { return problem }
        guard let now = Self.device(root.path), now == root.device else {
            return "destination \(root.path) is no longer available (disconnected?); nothing was written there"
        }
        return nil
    }

    static func device(_ path: String) -> dev_t? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_dev : nil
    }

    /// `/Volumes/<name>/…` where `/Volumes/<name>` isn't a mounted volume.
    static func unmountedVolume(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        let volume = "/Volumes/\(parts[1])"
        guard let dev = device(volume), let parent = device("/Volumes"), dev != parent else {
            return "\(volume) isn't connected; connect the drive or share and try again"
        }
        return nil
    }
}
