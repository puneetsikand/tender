import CryptoKit
import Foundation
import System

/// Copies source files to any number of destinations, reading each source exactly once.
///
/// For each file, chunks are read from the source (bypassing the page cache), hashed with
/// SHA-256, and handed to every destination's writer in parallel. The next chunk is read
/// while the current one is being written. Destinations fail independently.
/// Verification by re-reading is M3; this engine produces the source hash it needs.
public struct CopyEngine: Sendable {
    public let options: CopyOptions

    public init(options: CopyOptions = CopyOptions()) {
        self.options = options
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

    /// Copies one file. Runs on `BlockingIOExecutor` threads; each chunk's destination writes
    /// and the next read run as parallel child tasks.
    func copy(_ request: CopyRequest, index: Int, _ out: AsyncStream<CopyEvent>.Continuation) async -> FileCopyResult {
        func sourceFailure(_ reason: String, read: Int64 = 0, writers: [PartialWriter] = []) -> FileCopyResult {
            writers.forEach { $0.abandon() }
            return FileCopyResult(request: request, sourceSHA256: nil, bytesRead: read, sourceError: reason,
                                  destinations: request.destinations.map { .failed($0, reason: "source: \(reason)") })
        }

        let src: FileDescriptor
        do {
            src = try FileDescriptor.open(FilePath(request.source.url.path), .readOnly)
        } catch {
            return sourceFailure("open: \(error.localizedDescription)")
        }
        defer { try? src.close() }
        _ = fcntl(src.rawValue, F_NOCACHE, 1)

        let writers = request.destinations.map { PartialWriter(finalURL: $0, expectedSize: request.source.size) }
        var hasher = SHA256()
        var total: Int64 = 0

        do {
            var chunk = try Self.readChunk(src, size: options.chunkSize)
            while !chunk.isEmpty {
                if Task.isCancelled { return sourceFailure("cancelled", read: total, writers: writers) }
                let current = chunk
                hasher.update(data: current)
                total += Int64(current.count)

                // Write this chunk to every destination while the next chunk is read. All of
                // these child tasks inherit the BlockingIOExecutor preference.
                let live = writers.filter { $0.failure == nil }
                async let nextChunk = Self.readChunk(src, size: options.chunkSize)
                await withTaskGroup(of: Void.self) { group in
                    for writer in live { group.addTask { writer.write(current) } }
                }
                chunk = try await nextChunk
                out.yield(.progress(index: index, bytesDone: total))
            }
        } catch {
            return sourceFailure("read: \(error.localizedDescription)", read: total, writers: writers)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let outcomes = writers.map {
            $0.finish(fullSync: options.fullSync, modificationDate: request.source.modificationDate)
        }
        return FileCopyResult(request: request, sourceSHA256: digest, bytesRead: total,
                              sourceError: nil, destinations: outcomes)
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
