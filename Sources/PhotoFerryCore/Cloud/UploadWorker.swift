import CryptoKit
import Foundation

/// Works through the upload queue in the ledger: verified local copies → S3-compatible buckets.
///
/// Integrity: every upload is signed with the file's SHA-256, and the server rejects a body that
/// doesn't match (verified against Backblaze B2 on 2026-11-08). A single PUT is signed with the card
/// hash itself, so success proves card → bucket. A multipart upload signs each part's hash, while
/// the whole local file is hashed as it's read; if that doesn't equal the card hash, the upload is
/// abandoned before it's completed (the local copy changed since it was verified).
public actor UploadWorker {
    public typealias SecretProvider = @Sendable (String) throws -> String

    let ledger: Ledger
    let secret: SecretProvider
    let session: URLSession
    public let singlePutLimit: Int64
    public let partSize: Int
    public let concurrency: Int
    private var busy: Set<Int64> = []
    private var running = false

    public init(ledger: Ledger, secret: @escaping SecretProvider = { try S3Keychain.secret(forKeyID: $0) },
                session: URLSession = .shared, singlePutLimit: Int64 = 32 << 20, partSize: Int = 16 << 20, concurrency: Int = 2) {
        self.ledger = ledger
        self.secret = secret
        self.session = session
        self.singlePutLimit = singlePutLimit
        self.partSize = partSize
        self.concurrency = concurrency
    }

    public struct Summary: Sendable, Hashable {
        public var done = 0
        public var failed = 0
        public var retried = 0
    }

    /// Uploads until nothing is runnable now (uploads backing off are left for later).
    public func runUntilIdle() async -> Summary {
        var summary = Summary()
        while true {
            let batch = nextBatch()
            if batch.isEmpty { return summary }
            await withTaskGroup(of: Outcome.self) { group in
                for record in batch { group.addTask { await self.process(record) } }
                for await outcome in group {
                    switch outcome {
                    case .done: summary.done += 1
                    case .failed: summary.failed += 1
                    case .retry: summary.retried += 1
                    }
                }
            }
        }
    }

    /// Keeps the queue moving for as long as the process lives: runs, then checks again every
    /// `interval` (and when `nudge()` is called).
    public func start(interval: Duration = .seconds(15)) async {
        guard !running else { return }
        running = true
        while running {
            _ = await runUntilIdle()
            try? await Task.sleep(for: interval)
        }
    }

    public func stop() { running = false }

    private func nextBatch() -> [UploadRecord] {
        var batch: [UploadRecord] = []
        while batch.count < concurrency, let r = try? ledger.nextUpload(excluding: busy.union(batch.map(\.id))) {
            batch.append(r)
        }
        return batch
    }

    enum Outcome { case done, failed, retry }

    private func process(_ r: UploadRecord) async -> Outcome {
        busy.insert(r.id)
        defer { busy.remove(r.id) }
        try? ledger.updateUpload(r.id, "state = 'uploading', attempts = attempts + 1", [])
        do {
            let client = S3Client(endpoint: r.target.endpoint, keyID: r.target.keyID, secret: try secret(r.target.keyID), session: session)
            let result = try await upload(r, client)
            try? ledger.updateUpload(r.id, "state = 'done', etag = ?, versionId = ?, bytesDone = size, completedAt = ?, lastError = NULL",
                                     [result.etag, result.versionID, Date.now])
            return .done
        } catch let failure as UploadFailure {
            switch failure {
            case .permanent(let why):
                try? ledger.updateUpload(r.id, "state = 'failed', lastError = ?", [why])
                return .failed
            case .retry(let why):
                // Exponential backoff: 10 s, 20 s, 40 s … up to 15 min.
                let wait = min(900.0, 10 * pow(2, Double(max(0, r.attempts))))
                try? ledger.updateUpload(r.id, "state = 'queued', lastError = ?, notBefore = ?", [why, Date.now.addingTimeInterval(wait)])
                return .retry
            }
        } catch {
            try? ledger.updateUpload(r.id, "state = 'failed', lastError = ?", ["\(error)"])
            return .failed
        }
    }

    enum UploadFailure: Error {
        case permanent(String)
        case retry(String)
    }

    private func upload(_ r: UploadRecord, _ s3: S3Client) async throws -> S3Client.PutResult {
        let file = URL(fileURLWithPath: r.localPath)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: r.localPath))?[.size] as? Int64 else {
            throw UploadFailure.permanent("the local copy is missing: \(r.localPath)")
        }
        guard size == r.size else { throw UploadFailure.permanent("the local copy changed size since it was verified (\(r.size) → \(size) bytes)") }

        do {
            if r.size <= singlePutLimit {
                // Signed with the card hash: success proves the bucket holds the card's bytes.
                return try await s3.putFile(r.key, file: file, sha256: r.sha256)
            }
            return try await multipart(r, s3, file)
        } catch let e as S3Error {
            throw try classify(e, r)
        } catch let e as URLError {
            throw UploadFailure.retry("network: \(e.localizedDescription)")
        }
    }

    /// Turns a server error into "fix something" (permanent) or "try again later" (retry).
    private func classify(_ e: S3Error, _ r: UploadRecord) throws -> UploadFailure {
        switch (e.status, e.code) {
        case (400, "IncompleteBody"), (400, "XAmzContentSHA256Mismatch"), (400, "BadDigest"):
            // The server says the body didn't match the signed hash. Was it the network, or the local copy?
            let actual = try? Self.sha256(of: URL(fileURLWithPath: r.localPath))
            return actual == r.sha256
                ? .retry("the server rejected the body as not matching its hash (\(e.code)); will retry")
                : .permanent("the local copy no longer matches the card hash; not uploaded (re-copy it from the card)")
        case (401, _), (403, _):
            return .permanent("the bucket refused the key (\(e.code): \(e.message)); check the key and its permissions")
        case (404, "NoSuchBucket"):
            return .permanent("bucket \(r.target.bucket) doesn't exist at \(r.target.host)")
        case (500..., _), (408, _), (429, _):
            return .retry("\(e.status) \(e.code): \(e.message)")
        default:
            return .permanent("\(e)")
        }
    }

    private func multipart(_ r: UploadRecord, _ s3: S3Client, _ file: URL) async throws -> S3Client.PutResult {
        var uploadID = r.multipartID
        var done = (try? ledger.uploadParts(r.id)) ?? [:]
        if uploadID == nil {
            let id = try await s3.createMultipartUpload(r.key)
            try ledger.updateUpload(r.id, "multipartId = ?", [id])
            uploadID = id
            done = [:]
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var whole = SHA256()
        var number = 1
        var offset: Int64 = 0
        do {
            while true {
                let part = try handle.read(upToCount: partSize) ?? Data()
                if part.isEmpty { break }
                whole.update(data: part)
                offset += Int64(part.count)
                if done[number] == nil {
                    let etag = try await s3.uploadPart(r.key, uploadID: uploadID!, partNumber: number, body: part)
                    done[number] = etag
                    try ledger.recordUploadPart(r.id, number: number, etag: etag, bytesDone: offset)
                }
                number += 1
            }
        } catch let e as S3Error where e.code == "NoSuchUpload" {
            try? ledger.clearUploadParts(r.id)          // the server forgot the upload; start over next time
            throw UploadFailure.retry("the server lost the multipart upload; restarting it")
        }
        // The bytes uploaded must be the card's bytes, whatever each part said about itself.
        guard Self.hex(whole.finalize()) == r.sha256 else {
            try? await s3.abortMultipartUpload(r.key, uploadID: uploadID!)
            try? ledger.clearUploadParts(r.id)
            throw UploadFailure.permanent("the local copy no longer matches the card hash; upload abandoned (re-copy it from the card)")
        }
        let parts = done.sorted { $0.key < $1.key }.map { (number: $0.key, etag: $0.value) }
        return try await s3.completeMultipartUpload(r.key, uploadID: uploadID!, parts: parts)
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    static func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }
}
