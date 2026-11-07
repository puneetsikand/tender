import CryptoKit
import Foundation
import System

/// Copies source files to any number of destinations, reading each source once, and
/// verifies every copy before it gets its final name.
///
/// Per file: evict the source from the page cache, read it in chunks (`F_NOCACHE`) while
/// hashing with SHA-256, and hand each chunk to every destination writer in parallel, with
/// the next read overlapped. Then seal each partial, verify it (`CopyOptions.verify`), and
/// rename only the copies that passed. Destinations fail independently.
public struct CopyEngine: Sendable {
    public let options: CopyOptions
    /// Test hook: runs on each sealed partial before verification (fault injection).
    let afterSeal: (@Sendable (URL) -> Void)?
    /// Test hook: runs on the source after the copy read, before a paranoid re-read.
    let beforeSourceReread: (@Sendable (URL) -> Void)?

    public init(options: CopyOptions = CopyOptions()) {
        self.init(options: options, afterSeal: nil, beforeSourceReread: nil)
    }

    init(options: CopyOptions, afterSeal: (@Sendable (URL) -> Void)?, beforeSourceReread: (@Sendable (URL) -> Void)?) {
        self.options = options
        self.afterSeal = afterSeal
        self.beforeSourceReread = beforeSourceReread
    }

    /// Runs the job. Cancelling the consuming task stops it and removes partial files.
    public func run(_ requests: [CopyRequest]) -> AsyncStream<CopyEvent> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskExecutorPreference(BlockingIOExecutor.shared) {
                    await self.runAll(requests, continuation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runAll(_ requests: [CopyRequest], _ out: AsyncStream<CopyEvent>.Continuation) async {
        let clock = ContinuousClock()
        let start = clock.now
        var results = [FileCopyResult?](repeating: nil, count: requests.count)

        await withTaskGroup(of: (Int, FileCopyResult).self) { group in
            var next = 0
            func launch() {
                guard next < requests.count else { return }
                let index = next
                next += 1
                group.addTask {
                    out.yield(.fileStarted(index: index, requests[index].source))
                    return (index, await copy(requests[index], index: index, out))
                }
            }
            for _ in 0..<max(1, options.filesInFlight) { launch() }
            for await (index, result) in group {
                results[index] = result
                out.yield(.fileFinished(index: index, result))
                launch()
            }
        }

        let done = results.compactMap { $0 }
        out.yield(.finished(CopySummary(results: done,
                                        bytesRead: done.reduce(0) { $0 + $1.bytesRead },
                                        elapsed: clock.now - start)))
    }

    /// Copies and verifies one file. Runs on `BlockingIOExecutor` threads.
    func copy(_ request: CopyRequest, index: Int, _ out: AsyncStream<CopyEvent>.Continuation) async -> FileCopyResult {
        func sourceFailure(_ reason: String, read: Int64 = 0, writers: [PartialWriter] = []) -> FileCopyResult {
            writers.forEach { $0.abandon() }
            return FileCopyResult(request: request, sourceSHA256: nil, bytesRead: read, sourceError: reason,
                                  destinations: request.destinations.map { .failed($0, reason: "source: \(reason)") })
        }

        let sourcePath = request.source.url.path
        // Make the read come from the card, not from pages another program left cached.
        PageCache.evict(sourcePath)

        let writers = request.destinations.map { PartialWriter(finalURL: $0, expectedSize: request.source.size) }
        let sourceHash: String
        let total: Int64
        do {
            (sourceHash, total) = try await readSource(sourcePath, index: index, out) { chunk in
                let live = writers.filter { $0.failure == nil }
                await withTaskGroup(of: Void.self) { group in
                    for writer in live { group.addTask { writer.write(chunk) } }
                }
            }
        } catch is CancellationError {
            return sourceFailure("cancelled", writers: writers)
        } catch {
            return sourceFailure("read: \(error.localizedDescription)", writers: writers)
        }

        out.yield(.verifying(index: index))
        let sealed = writers.filter { $0.seal(fullSync: options.fullSync) }
        sealed.forEach { afterSeal?($0.partialURL) }

        // Paranoid: the source must read back identically before any copy is trusted.
        if options.verify == .paranoid {
            beforeSourceReread?(request.source.url)
            PageCache.evict(sourcePath)
            let again = try? await readSource(sourcePath, index: nil, nil) { _ in }
            guard let again, again.sha256 == sourceHash, again.bytes == total else {
                return sourceFailure("source read unstable: a second read of the card gave different data", read: total, writers: writers)
            }
        }

        var verifications: [ObjectIdentifier: DestinationVerification] = [:]
        if options.verify == .bytes {
            verifications = await compareBytes(sourcePath, total: total, writers: sealed)
        } else {
            await withTaskGroup(of: (ObjectIdentifier, DestinationVerification?).self) { group in
                for writer in sealed {
                    group.addTask { (ObjectIdentifier(writer), verify(writer, sourceHash: sourceHash, size: total)) }
                }
                for await (id, v) in group { if let v { verifications[id] = v } }
            }
        }

        let outcomes = writers.map { writer -> DestinationOutcome in
            guard let v = verifications[ObjectIdentifier(writer)] else {
                if writer.failure == nil { writer.reject("verification failed") }
                return writer.commit(verification: DestinationVerification(mode: options.verify, path: .notRead, destinationSHA256: nil),
                                     modificationDate: nil)
            }
            return writer.commit(verification: v, modificationDate: request.source.modificationDate)
        }
        return FileCopyResult(request: request, sourceSHA256: sourceHash, bytesRead: total,
                              sourceError: nil, destinations: outcomes)
    }

    // MARK: Reading

    /// Reads a file in chunks with `F_NOCACHE`, hashing as it goes; `consume` gets each chunk
    /// while the next one is read. Returns the SHA-256 (hex) and byte count.
    private func readSource(_ path: String, index: Int?, _ out: AsyncStream<CopyEvent>.Continuation?,
                            consume: @Sendable (Data) async -> Void) async throws -> (sha256: String, bytes: Int64) {
        let fd = try FileDescriptor.open(FilePath(path), .readOnly)
        defer { try? fd.close() }
        _ = fcntl(fd.rawValue, F_NOCACHE, 1)
        var hasher = SHA256()
        var total: Int64 = 0
        var chunk = try Self.readChunk(fd, size: options.chunkSize)
        while !chunk.isEmpty {
            try Task.checkCancellation()
            let current = chunk
            hasher.update(data: current)
            total += Int64(current.count)
            async let nextChunk = Self.readChunk(fd, size: options.chunkSize)
            await consume(current)
            chunk = try await nextChunk
            if let index { out?.yield(.progress(index: index, bytesDone: total)) }
        }
        return (Self.hex(hasher.finalize()), total)
    }

    // MARK: Verification

    /// Verifies one sealed partial by size or by re-reading it. Nil = failed (writer rejected).
    private func verify(_ writer: PartialWriter, sourceHash: String, size: Int64) -> DestinationVerification? {
        let path = writer.partialURL.path
        let actualSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? -1
        guard actualSize == size else {
            writer.reject("verification failed: size \(actualSize), expected \(size)")
            return nil
        }
        if options.verify == .size {
            return DestinationVerification(mode: .size, path: .notRead, destinationSHA256: nil)
        }
        let readPath = Self.prepareForVerifyRead(path)
        guard let hash = try? Self.sha256(of: path, chunkSize: options.chunkSize) else {
            writer.reject("verification failed: could not re-read copy")
            return nil
        }
        guard hash == sourceHash else {
            writer.reject("verification failed: SHA-256 mismatch (copy \(hash.prefix(12))…, source \(sourceHash.prefix(12))…)")
            return nil
        }
        return DestinationVerification(mode: options.verify, path: readPath, destinationSHA256: hash)
    }

    /// Re-reads the source and every sealed copy in lockstep and compares the bytes.
    private func compareBytes(_ sourcePath: String, total: Int64, writers: [PartialWriter]) async -> [ObjectIdentifier: DestinationVerification] {
        var result: [ObjectIdentifier: DestinationVerification] = [:]
        PageCache.evict(sourcePath)
        let paths = writers.map { Self.prepareForVerifyRead($0.partialURL.path) }
        do {
            let src = try FileDescriptor.open(FilePath(sourcePath), .readOnly)
            defer { try? src.close() }
            _ = fcntl(src.rawValue, F_NOCACHE, 1)
            let dsts: [FileDescriptor?] = writers.map { try? FileDescriptor.open(FilePath($0.partialURL.path), .readOnly) }
            defer { dsts.forEach { try? $0?.close() } }
            for d in dsts { if let d { _ = fcntl(d.rawValue, F_NOCACHE, 1) } }
            var mismatch = [String?](repeating: nil, count: writers.count)
            for (i, d) in dsts.enumerated() where d == nil { mismatch[i] = "could not re-read copy" }
            var offset: Int64 = 0
            while true {
                let s = try Self.readChunk(src, size: options.chunkSize)
                for (i, d) in dsts.enumerated() where mismatch[i] == nil {
                    guard let d, let c = try? Self.readChunk(d, size: options.chunkSize) else { mismatch[i] = "read error"; continue }
                    if c != s { mismatch[i] = "bytes differ in chunk at offset \(offset)" }
                }
                if s.isEmpty { break }
                offset += Int64(s.count)
            }
            if offset != total { mismatch = mismatch.map { $0 ?? "source size changed between reads" } }
            for (i, w) in writers.enumerated() {
                if let m = mismatch[i] { w.reject("verification failed: \(m)") }
                else { result[ObjectIdentifier(w)] = DestinationVerification(mode: .bytes, path: paths[i], destinationSHA256: nil) }
            }
        } catch {
            writers.forEach { $0.reject("verification failed: source re-read: \(error.localizedDescription)") }
        }
        return result
    }

    /// Evicts a copy from the page cache and reports where the coming read will come from.
    static func prepareForVerifyRead(_ path: String) -> VerifyPath {
        if PageCache.isNetworkFilesystem(path) { return .server }
        guard let left = PageCache.evict(path) else { return .possiblyCached }
        return left == 0 ? .device : .possiblyCached
    }

    static func sha256(of path: String, chunkSize: Int) throws -> String {
        let fd = try FileDescriptor.open(FilePath(path), .readOnly)
        defer { try? fd.close() }
        _ = fcntl(fd.rawValue, F_NOCACHE, 1)
        var hasher = SHA256()
        while true {
            let chunk = try readChunk(fd, size: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads up to `size` bytes, looping over short reads. Empty at end of file.
    static func readChunk(_ fd: FileDescriptor, size: Int) throws -> Data {
        var data = Data(count: size)
        let n = try data.withUnsafeMutableBytes { buf -> Int in
            var filled = 0
            while filled < size {
                let r = try fd.read(into: UnsafeMutableRawBufferPointer(rebasing: buf[filled...]))
                if r == 0 { break }
                filled += r
            }
            return filled
        }
        data.removeSubrange(n...)
        return data
    }
}
