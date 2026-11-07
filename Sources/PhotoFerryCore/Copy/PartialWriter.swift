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
    private var fd: FileDescriptor?
    private(set) var failure: String?

    static func partialURL(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent().appendingPathComponent(".\(finalURL.lastPathComponent).pfpartial")
    }

    init(finalURL: URL, expectedSize: Int64) {
        self.finalURL = finalURL
        partialURL = Self.partialURL(for: finalURL)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: finalURL.path) {
                failure = "destination already exists"
                return
            }
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

    /// Renames a sealed, verified partial to its final name. Never replaces an existing file.
    func commit(verification: DestinationVerification, modificationDate: Date?) -> DestinationOutcome {
        if let failure { abandon(); return .failed(finalURL, reason: failure) }
        // RENAME_EXCL isn't supported everywhere (some network filesystems), so fall back to
        // check-then-rename.
        var ok = renamex_np(partialURL.path, finalURL.path, UInt32(RENAME_EXCL)) == 0
        if !ok, errno == ENOTSUP || errno == EINVAL {
            ok = !FileManager.default.fileExists(atPath: finalURL.path)
                && rename(partialURL.path, finalURL.path) == 0
        }
        guard ok else {
            let reason = errno == EEXIST ? "destination already exists" : "rename: errno \(errno)"
            abandon()
            return .failed(finalURL, reason: reason)
        }
        if let modificationDate {
            try? FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: finalURL.path)
        }
        return .written(finalURL, verification)
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
