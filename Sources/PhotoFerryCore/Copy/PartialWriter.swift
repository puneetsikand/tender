import Foundation
import System

/// Writes one destination copy as a hidden `.<name>.pfpartial` file, then renames it into place.
///
/// A copy is never visible under its final name until every byte is written and synced.
/// Not thread-safe: the engine calls it from one task at a time. A writer that fails
/// remembers why and turns later calls into no-ops, so one bad destination doesn't stop the others.
final class PartialWriter: @unchecked Sendable {
    let finalURL: URL
    let partialURL: URL
    /// On a name clash at commit, take the next free " 2", " 3" … name instead of failing.
    let keepBothOnClash: Bool
    private var fd: FileDescriptor?
    private(set) var failure: String?

    static func partialURL(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent().appendingPathComponent(".\(finalURL.lastPathComponent).pfpartial")
    }

    init(finalURL: URL, expectedSize: Int64, keepBothOnClash: Bool = false, partialTag: String = "") {
        self.finalURL = finalURL
        self.keepBothOnClash = keepBothOnClash
        let p = Self.partialURL(for: finalURL)
        partialURL = partialTag.isEmpty ? p : p.deletingPathExtension().appendingPathExtension("\(partialTag).pfpartial")
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A partial with our name is always ours, left by an interrupted run.
            try? fm.removeItem(at: partialURL)
            let fd = try FileDescriptor.open(FilePath(partialURL.path), .writeOnly,
                                             options: [.create, .exclusiveCreate], permissions: [.ownerReadWrite, .groupRead, .otherRead])
            _ = fcntl(fd.rawValue, F_NOCACHE, 1)
            Self.preallocate(fd, size: expectedSize)
            self.fd = fd
        } catch {
            failure = "open: \(error.localizedDescription)"
        }
    }

    func write(_ chunk: Data) {
        guard failure == nil, let fd else { return }
        do {
            try chunk.withUnsafeBytes { _ = try fd.writeAll($0) }
        } catch {
            fail("write: \(error.localizedDescription)")
        }
    }

    /// Syncs and closes the partial. Returns false (and records why) on failure.
    func seal(fullSync: Bool) -> Bool {
        guard failure == nil, let fd else { abandon(); return false }
        if fullSync, fcntl(fd.rawValue, F_FULLFSYNC) == -1, fsync(fd.rawValue) == -1 {
            fail("fsync: errno \(errno)")
            return false
        }
        do { try fd.close() } catch { self.fd = nil; fail("close: \(error.localizedDescription)"); return false }
        self.fd = nil
        return true
    }

    /// Marks a sealed partial as failed (e.g. verification) and deletes it.
    func reject(_ reason: String) {
        fail(reason)
    }

    /// Renames a sealed, verified partial to its final name. Never replaces an existing file:
    /// on a clash it fails, or with `keepBothOnClash` takes the next free " 2", " 3" … name.
    func commit(verification: DestinationVerification, modificationDate: Date?) -> DestinationOutcome {
        if let failure { abandon(); return .failed(finalURL, reason: failure) }
        var target = finalURL
        var n = 1
        while true {
            if Self.renameExclusive(partialURL, target) { break }
            guard errno == EEXIST, keepBothOnClash, n < 1000 else {
                let reason = errno == EEXIST ? "a different file with this name already exists" : "rename: errno \(errno)"
                abandon()
                return .failed(finalURL, reason: reason)
            }
            n += 1
            target = Self.suffixed(finalURL, n)
        }
        if let modificationDate {
            try? FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: target.path)
        }
        return .written(target, verification)
    }

    /// `SDIM0199.DNG` → `SDIM0199 2.DNG`.
    static func suffixed(_ url: URL, _ n: Int) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
    }

    /// Rename that never replaces. RENAME_EXCL isn't supported everywhere (some network
    /// filesystems), so fall back to check-then-rename there. Sets errno = EEXIST on a clash.
    private static func renameExclusive(_ from: URL, _ to: URL) -> Bool {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return true }
        guard errno == ENOTSUP || errno == EINVAL else { return false }
        if FileManager.default.fileExists(atPath: to.path) { errno = EEXIST; return false }
        return rename(from.path, to.path) == 0
    }

    /// Closes and deletes the partial file.
    func abandon() {
        try? fd?.close()
        fd = nil
        try? FileManager.default.removeItem(at: partialURL)
    }

    private func fail(_ reason: String) {
        failure = reason
        abandon()
    }

    private static func preallocate(_ fd: FileDescriptor, size: Int64) {
        guard size > 0 else { return }
        var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG), fst_posmode: F_PEOFPOSMODE,
                             fst_offset: 0, fst_length: off_t(size), fst_bytesalloc: 0)
        if fcntl(fd.rawValue, F_PREALLOCATE, &store) == -1 {
            store.fst_flags = UInt32(F_ALLOCATEALL)
            _ = fcntl(fd.rawValue, F_PREALLOCATE, &store)   // best effort; not all filesystems support it
        }
    }
}
