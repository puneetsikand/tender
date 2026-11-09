import Foundation
import GRDB

/// The ingest ledger (PLAN §8A.4): every job, every file read, every copy made, with hashes.
///
/// One SQLite file in WAL mode, shared by the copy service and in-process runners. Plain
/// typed columns, no JSON. It is a record of what happened, not the source of truth for
/// photos: the folders are.
public final class Ledger: Sendable {
    let pool: DatabasePool

    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["PF_LEDGER"] { return URL(fileURLWithPath: override) }
        return URL.applicationSupportDirectory.appending(path: "PhotoFerry/ledger.sqlite")
    }

    public init(url: URL = Ledger.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        pool = try DatabasePool(path: url.path)
        try Self.migrator.migrate(pool)
        try markOrphanedJobs()
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "job") { t in
                t.primaryKey("id", .text)                    // UUID
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("status", .text).notNull()          // running | finished | cancelled | interrupted
                t.column("pid", .integer).notNull()          // process running the job, for orphan detection
                t.column("sourceRoot", .text).notNull()
                t.column("volumeLabel", .text)
                t.column("volumeUUID", .text)
                t.column("cardKey", .text).indexed()
                t.column("verifyMode", .text).notNull()
                t.column("filesTotal", .integer).notNull()
                t.column("filesFailed", .integer)
                t.column("bytesRead", .integer)
            }
            try db.create(table: "jobDestination") { t in
                t.column("jobId", .text).notNull().references("job", onDelete: .cascade)
                t.column("root", .text).notNull()
                t.column("manifestPath", .text)
                t.primaryKey(["jobId", "root"])
            }
            try db.create(table: "file") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("jobId", .text).notNull().indexed().references("job", onDelete: .cascade)
                t.column("relativePath", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("modifiedAt", .datetime)
                t.column("sha256", .text).indexed()
                t.column("sourceError", .text)
            }
            try db.create(table: "copy") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileId", .integer).notNull().indexed().references("file", onDelete: .cascade)
                t.column("path", .text).notNull().indexed()
                t.column("outcome", .text).notNull()         // written | present (identical file already there) | failed
                t.column("reason", .text)
                t.column("verifyMode", .text)
                t.column("verifyPath", .text)                // device | server | possiblyCached | notRead
                t.column("destinationSha256", .text)
            }
        }
        m.registerMigration("v2: capture metadata, workflow") { db in
            try db.alter(table: "job") { t in t.add(column: "workflowName", .text) }
            try db.alter(table: "file") { t in
                t.add(column: "capturedAt", .datetime)
                t.add(column: "captureUTCOffset", .integer)   // seconds; NULL when the camera recorded none
                t.add(column: "cameraMake", .text)
                t.add(column: "cameraModel", .text)
                t.add(column: "bodySerial", .text).indexed()
                t.add(column: "lensModel", .text)
            }
        }
        m.registerMigration("v3: deleted from source") { db in
            try db.alter(table: "file") { t in t.add(column: "deletedFromSourceAt", .datetime) }
        }
        m.registerMigration("v4: upload queue") { db in
            try db.create(table: "upload") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("jobId", .text)
                t.column("relativePath", .text).notNull()        // on the card
                t.column("localPath", .text).notNull()           // the verified local copy it's read from
                t.column("sha256", .text).notNull()              // the card hash; signed as the payload hash
                t.column("size", .integer).notNull()
                t.column("destinationId", .text).notNull()
                t.column("host", .text).notNull()
                t.column("bucket", .text).notNull()
                t.column("objectKey", .text).notNull()
                t.column("keyId", .text).notNull()
                t.column("state", .text).notNull().indexed()     // queued | uploading | done | failed
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("notBefore", .datetime)                 // backoff: don't retry before this
                t.column("lastError", .text)
                t.column("multipartId", .text)
                t.column("bytesDone", .integer).notNull().defaults(to: 0)
                t.column("etag", .text)
                t.column("versionId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("completedAt", .datetime)
            }
            try db.create(index: "upload_object", on: "upload", columns: ["host", "bucket", "objectKey"])
            try db.create(table: "uploadPart") { t in
                t.column("uploadId", .integer).notNull().references("upload", onDelete: .cascade)
                t.column("partNumber", .integer).notNull()
                t.column("etag", .text).notNull()
                t.primaryKey(["uploadId", "partNumber"])
            }
        }
        return m
    }

    // MARK: Writing

    public func beginJob(_ job: CopyJob, at date: Date = .now) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO job (id, startedAt, status, pid, sourceRoot, volumeLabel, volumeUUID, cardKey, verifyMode, filesTotal, workflowName)
                VALUES (?, ?, 'running', ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [job.id.uuidString, date, Int(getpid()), job.source.root.path, job.source.volumeLabel,
                                 job.source.volumeUUID, job.source.cardKey, job.options.verify.rawValue, job.requests.count,
                                 job.workflowName])
            for root in job.destinationRoots {
                try db.execute(sql: "INSERT INTO jobDestination (jobId, root) VALUES (?, ?)",
                               arguments: [job.id.uuidString, root.path])
            }
        }
    }

    /// Records one finished file as soon as it's done, so a job that dies midway still has
    /// an accurate record of what was copied.
    public func recordFile(job: UUID, _ r: FileCopyResult) throws {
        try pool.write { db in
            let m = r.request.metadata
            try db.execute(sql: """
                INSERT INTO file (jobId, relativePath, size, modifiedAt, sha256, sourceError,
                                  capturedAt, captureUTCOffset, cameraMake, cameraModel, bodySerial, lensModel)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [job.uuidString, r.request.source.relativePath, r.request.source.size,
                                 r.request.source.modificationDate, r.sourceSHA256, r.sourceError,
                                 m?.captureDate, m?.captureUTCOffsetSeconds, m?.cameraMake, m?.cameraModel,
                                 m?.bodySerial, m?.lensModel])
            let fileId = db.lastInsertedRowID
            for d in r.destinations {
                switch d {
                case let .written(url, v), let .alreadyPresent(url, v):
                    try db.execute(sql: """
                        INSERT INTO copy (fileId, path, outcome, verifyMode, verifyPath, destinationSha256)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [fileId, url.path, d.isWritten ? "written" : "present", v.mode.rawValue,
                                         v.path.rawValue, v.destinationSHA256])
                case let .failed(url, reason):
                    try db.execute(sql: "INSERT INTO copy (fileId, path, outcome, reason) VALUES (?, ?, 'failed', ?)",
                                   arguments: [fileId, url.path, reason])
                }
            }
        }
    }

    public func finishJob(_ job: UUID, status: JobStatus, summary: CopySummary?, manifests: [URL: URL], at date: Date = .now) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE job SET status = ?, finishedAt = ?, filesFailed = ?, bytesRead = ? WHERE id = ?",
                           arguments: [status.rawValue, date, summary?.failed.count, summary?.bytesRead, job.uuidString])
            for (root, manifest) in manifests {
                try db.execute(sql: "UPDATE jobDestination SET manifestPath = ? WHERE jobId = ? AND root = ?",
                               arguments: [manifest.path, job.uuidString, root.path])
            }
        }
    }

    public func recordDeletedFromSource(job: UUID, relativePaths: [String], at date: Date = .now) throws {
        guard !relativePaths.isEmpty else { return }
        try pool.write { db in
            for p in relativePaths {
                try db.execute(sql: "UPDATE file SET deletedFromSourceAt = ? WHERE jobId = ? AND relativePath = ?",
                               arguments: [date, job.uuidString, p])
            }
        }
    }

    /// Jobs left `running` by a process that no longer exists were interrupted (crash, kill, power loss).
    func markOrphanedJobs() throws {
        try pool.write { db in
            let running = try Row.fetchAll(db, sql: "SELECT id, pid FROM job WHERE status = 'running'")
            for row in running {
                let pid: Int32 = row["pid"]
                if kill(pid, 0) != 0 && errno == ESRCH {
                    try db.execute(sql: "UPDATE job SET status = 'interrupted' WHERE id = ?", arguments: [row["id"] as String])
                }
            }
        }
    }

    // MARK: Upload queue

    /// Queues an upload unless the same object (endpoint, bucket, key) with the same content is
    /// already queued, uploading or done. A failed one with the same content is queued again.
    @discardableResult
    public func enqueueUpload(job: UUID?, relativePath: String, localPath: String, sha256: String, size: Int64,
                              remote: RemoteDestination, at date: Date = .now) throws -> Bool {
        try pool.write { db in
            let existing = try Row.fetchOne(db, sql: """
                SELECT id, state FROM upload WHERE host = ? AND bucket = ? AND objectKey = ? AND sha256 = ?
                ORDER BY id DESC LIMIT 1
                """, arguments: [remote.target.host, remote.target.bucket, remote.key, sha256])
            if let existing {
                let state: String = existing["state"]
                guard state == "failed" else { return false }
                try db.execute(sql: "UPDATE upload SET state = 'queued', attempts = 0, notBefore = NULL, lastError = NULL, localPath = ? WHERE id = ?",
                               arguments: [localPath, existing["id"] as Int64])
                return true
            }
            try db.execute(sql: """
                INSERT INTO upload (jobId, relativePath, localPath, sha256, size, destinationId, host, bucket, objectKey, keyId, state, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?)
                """, arguments: [job?.uuidString, relativePath, localPath, sha256, size, remote.destinationID, remote.target.host,
                                 remote.target.bucket, remote.key, remote.target.keyID, date])
            return true
        }
    }

    /// The next upload that may run now (queued or interrupted mid-upload, not backing off).
    public func nextUpload(now: Date = .now, excluding busy: Set<Int64> = []) throws -> UploadRecord? {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM upload WHERE state IN ('queued', 'uploading') AND (notBefore IS NULL OR notBefore <= ?)
                ORDER BY id LIMIT 50
                """, arguments: [now]).map(UploadRecord.init(row:)).first { !busy.contains($0.id) }
        }
    }

    public func uploads(limit: Int = 500) throws -> [UploadRecord] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM upload ORDER BY id DESC LIMIT ?", arguments: [limit]).map(UploadRecord.init(row:))
        }
    }

    public func uploadCounts() throws -> [UploadRecord.State: Int] {
        try pool.read { db in
            var out: [UploadRecord.State: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT state, COUNT(*) AS n FROM upload GROUP BY state") {
                if let s = UploadRecord.State(rawValue: row["state"]) { out[s] = row["n"] }
            }
            return out
        }
    }

    func updateUpload(_ id: Int64, _ sql: String, _ args: StatementArguments) throws {
        try pool.write { db in try db.execute(sql: "UPDATE upload SET \(sql) WHERE id = ?", arguments: args + [id]) }
    }

    func uploadParts(_ id: Int64) throws -> [Int: String] {
        try pool.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT partNumber, etag FROM uploadPart WHERE uploadId = ?",
                                                              arguments: [id]).map { ($0["partNumber"] as Int, $0["etag"] as String) })
        }
    }

    func recordUploadPart(_ id: Int64, number: Int, etag: String, bytesDone: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO uploadPart (uploadId, partNumber, etag) VALUES (?, ?, ?)", arguments: [id, number, etag])
            try db.execute(sql: "UPDATE upload SET bytesDone = ? WHERE id = ?", arguments: [bytesDone, id])
        }
    }

    func clearUploadParts(_ id: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM uploadPart WHERE uploadId = ?", arguments: [id])
            try db.execute(sql: "UPDATE upload SET multipartId = NULL, bytesDone = 0 WHERE id = ?", arguments: [id])
        }
    }

    /// Whether this object is already uploaded (state done) with this content.
    public func isUploaded(_ remote: RemoteDestination, sha256: String?) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM upload WHERE host = ? AND bucket = ? AND objectKey = ? AND state = 'done'
                              AND (? IS NULL OR sha256 = ?))
                """, arguments: [remote.target.host, remote.target.bucket, remote.key, sha256, sha256]) ?? false
        }
    }

    /// Puts failed uploads back in the queue (after fixing credentials, reconnecting a drive …).
    @discardableResult
    public func retryFailedUploads() throws -> Int {
        try pool.write { db in
            try db.execute(sql: "UPDATE upload SET state = 'queued', attempts = 0, notBefore = NULL WHERE state = 'failed'")
            return db.changesCount
        }
    }

    /// SHA-256 recorded for a verified copy at this path (for re-queueing uploads of earlier copies).
    public func sha256(ofCopyAt path: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT f.sha256 FROM copy c JOIN file f ON f.id = c.fileId
                WHERE c.path = ? AND c.outcome IN ('written', 'present') AND f.sha256 IS NOT NULL ORDER BY c.id DESC LIMIT 1
                """, arguments: [path])
        }
    }

    // MARK: Reading

    public func recentJobs(limit: Int = 20) throws -> [JobRecord] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT j.*, (SELECT COUNT(*) FROM file f WHERE f.jobId = j.id) AS filesRecorded
                FROM job j ORDER BY startedAt DESC LIMIT ?
                """, arguments: [limit]).map(JobRecord.init(row:))
        }
    }

    /// Of the given (card file, destination path) pairs, the destination paths that already hold a
    /// verified copy of that same card file (same relative path, size and modification date)
    /// according to the ledger *and* still exist with that size.
    public func previouslyCopied(_ checks: [(source: SourceFile, destination: URL)]) throws -> Set<String> {
        try pool.read { db in
            var found = Set<String>()
            let statement = try db.makeStatement(sql: """
                SELECT f.modifiedAt FROM copy c JOIN file f ON f.id = c.fileId
                WHERE c.path = ? AND c.outcome IN ('written', 'present') AND f.relativePath = ? AND f.size = ?
                """)
            for (source, destination) in checks {
                let dates = try Date?.fetchAll(statement, arguments: [destination.path, source.relativePath, source.size])
                guard dates.contains(where: { Self.sameInstant($0, source.modificationDate) }) else { continue }
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64
                if size == source.size { found.insert(destination.path) }
            }
            return found
        }
    }

    /// Dates round-trip through SQLite with millisecond precision.
    static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) < 0.002
        default: false
        }
    }

    /// Verified copies of content with this SHA-256, anywhere, ever. Basis for duplicate checks (PLAN §6).
    public func verifiedCopies(sha256: String) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT c.path FROM copy c JOIN file f ON f.id = c.fileId
                WHERE f.sha256 = ? AND c.outcome IN ('written', 'present') ORDER BY c.id
                """, arguments: [sha256])
        }
    }
}

public enum JobStatus: String, Sendable, Codable {
    case running, finished, cancelled, interrupted
}

public struct JobRecord: Sendable, Hashable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: JobStatus
    public let sourceRoot: String
    public let volumeLabel: String?
    public let cardKey: String?
    public let workflowName: String?
    public let verifyMode: String
    public let filesTotal: Int
    public let filesRecorded: Int
    public let filesFailed: Int?
    public let bytesRead: Int64?

    init(row: Row) {
        id = UUID(uuidString: row["id"]) ?? UUID()
        startedAt = row["startedAt"]
        finishedAt = row["finishedAt"]
        status = JobStatus(rawValue: row["status"]) ?? .interrupted
        sourceRoot = row["sourceRoot"]
        volumeLabel = row["volumeLabel"]
        cardKey = row["cardKey"]
        workflowName = row["workflowName"]
        verifyMode = row["verifyMode"]
        filesTotal = row["filesTotal"]
        filesRecorded = row["filesRecorded"]
        filesFailed = row["filesFailed"]
        bytesRead = row["bytesRead"]
    }
}

/// One row of the upload queue.
public struct UploadRecord: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable { case queued, uploading, done, failed }
    public let id: Int64
    public let relativePath: String
    public let localPath: String
    public let sha256: String
    public let size: Int64
    public let destinationID: String
    public let target: S3Target
    public let key: String
    public let state: State
    public let attempts: Int
    public let notBefore: Date?
    public let lastError: String?
    public let multipartID: String?
    public let bytesDone: Int64
    public let etag: String?
    public let versionID: String?
    public let completedAt: Date?

    init(row: Row) {
        id = row["id"]
        relativePath = row["relativePath"]
        localPath = row["localPath"]
        sha256 = row["sha256"]
        size = row["size"]
        destinationID = row["destinationId"]
        target = S3Target(host: row["host"], bucket: row["bucket"], keyID: row["keyId"])
        key = row["objectKey"]
        state = State(rawValue: row["state"]) ?? .failed
        attempts = row["attempts"]
        notBefore = row["notBefore"]
        lastError = row["lastError"]
        multipartID = row["multipartId"]
        bytesDone = row["bytesDone"]
        etag = row["etag"]
        versionID = row["versionId"]
        completedAt = row["completedAt"]
    }
}

