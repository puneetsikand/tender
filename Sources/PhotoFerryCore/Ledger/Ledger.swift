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
                t.column("outcome", .text).notNull()         // written | failed
                t.column("reason", .text)
                t.column("verifyMode", .text)
                t.column("verifyPath", .text)                // device | server | possiblyCached | notRead
                t.column("destinationSha256", .text)
            }
        }
        return m
    }

    // MARK: Writing

    public func beginJob(_ job: CopyJob, at date: Date = .now) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO job (id, startedAt, status, pid, sourceRoot, volumeLabel, volumeUUID, cardKey, verifyMode, filesTotal)
                VALUES (?, ?, 'running', ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [job.id.uuidString, date, Int(getpid()), job.source.root.path, job.source.volumeLabel,
                                 job.source.volumeUUID, job.source.cardKey, job.options.verify.rawValue, job.requests.count])
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
            try db.execute(sql: "INSERT INTO file (jobId, relativePath, size, modifiedAt, sha256, sourceError) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [job.uuidString, r.request.source.relativePath, r.request.source.size,
                                       r.request.source.modificationDate, r.sourceSHA256, r.sourceError])
            let fileId = db.lastInsertedRowID
            for d in r.destinations {
                switch d {
                case let .written(url, v):
                    try db.execute(sql: """
                        INSERT INTO copy (fileId, path, outcome, verifyMode, verifyPath, destinationSha256)
                        VALUES (?, ?, 'written', ?, ?, ?)
                        """, arguments: [fileId, url.path, v.mode.rawValue, v.path.rawValue, v.destinationSHA256])
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

    // MARK: Reading

    public func recentJobs(limit: Int = 20) throws -> [JobRecord] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT j.*, (SELECT COUNT(*) FROM file f WHERE f.jobId = j.id) AS filesRecorded
                FROM job j ORDER BY startedAt DESC LIMIT ?
                """, arguments: [limit]).map(JobRecord.init(row:))
        }
    }

    /// Verified copies of content with this SHA-256, anywhere, ever. Basis for duplicate checks (PLAN §6).
    public func verifiedCopies(sha256: String) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT c.path FROM copy c JOIN file f ON f.id = c.fileId
                WHERE f.sha256 = ? AND c.outcome = 'written' ORDER BY c.id
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
        verifyMode = row["verifyMode"]
        filesTotal = row["filesTotal"]
        filesRecorded = row["filesRecorded"]
        filesFailed = row["filesFailed"]
        bytesRead = row["bytesRead"]
    }
}
