import Darwin
import Foundation

/// Unified buffer cache control for verification (PLAN §5).
///
/// Measured 2026-11-07 on macOS 27: `msync(MS_INVALIDATE)` on a shared read-only mapping
/// evicts a file's clean cached pages without root (100% → 0% resident), and files the
/// engine writes with `F_NOCACHE` are never resident afterwards. `mincore` confirms it.
enum PageCache {
    /// Evicts the file's cached pages, then returns the fraction still resident (0…1).
    /// Nil if the file can't be mapped (some network filesystems); empty files return 0.
    @discardableResult
    static func evict(_ path: String) -> Double? {
        withMapping(path) { p, len in
            _ = msync(p, len, MS_INVALIDATE)
            return residentFraction(p, len)
        }
    }

    /// Fraction of the file's pages currently resident in memory.
    static func resident(_ path: String) -> Double? {
        withMapping(path) { p, len in residentFraction(p, len) }
    }

    private static func withMapping(_ path: String, _ body: (UnsafeMutableRawPointer, Int) -> Double) -> Double? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let len = Int(st.st_size)
        if len == 0 { return 0 }
        guard let p = mmap(nil, len, PROT_READ, MAP_SHARED, fd, 0), p != MAP_FAILED else { return nil }
        defer { munmap(p, len) }
        return body(p, len)
    }

    private static func residentFraction(_ p: UnsafeMutableRawPointer, _ len: Int) -> Double {
        let page = Int(getpagesize())
        let pages = (len + page - 1) / page
        var vec = [CChar](repeating: 0, count: pages)
        guard mincore(p, len, &vec) == 0 else { return 1 }   // unknown: assume cached, never overclaim
        return Double(vec.lazy.filter { $0 & 1 != 0 }.count) / Double(pages)
    }

    /// True for filesystems where the server has its own cache we can't see or evict.
    static func isNetworkFilesystem(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let name = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ["smbfs", "nfs", "afpfs", "webdav", "ftp", "cifs"].contains(name)
    }
}
