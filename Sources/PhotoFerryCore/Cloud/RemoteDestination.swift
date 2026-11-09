import Foundation

/// An S3-compatible bucket a workflow backs up to (AWS S3, Backblaze B2, Wasabi, R2, MinIO).
/// No secrets here: the key's secret lives in the Keychain under `keyID`.
public struct S3Target: Sendable, Hashable, Codable {
    /// Endpoint host, e.g. `s3.us-east-005.backblazeb2.com`.
    public var host: String
    public var bucket: String
    /// Folder inside the bucket, e.g. `photos/` (may be empty).
    public var prefix: String
    public var keyID: String

    public init(host: String, bucket: String, prefix: String = "", keyID: String) {
        self.host = host
        self.bucket = bucket
        self.prefix = prefix
        self.keyID = keyID
    }

    public var endpoint: S3Endpoint { S3Endpoint(host: host, bucket: bucket) }

    /// Object key for a file's path under the destination: prefix + path, no leading slash.
    public func key(for relativePath: String) -> String {
        let p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return p.isEmpty ? relativePath : "\(p)/\(relativePath)"
    }

    public var displayName: String { "\(bucket)\(prefix.isEmpty ? "" : "/" + prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))" }
}

/// Where one file goes in a bucket. Uploads come from a verified local copy, after the card job.
public struct RemoteDestination: Sendable, Hashable, Codable {
    public let destinationID: String
    public let target: S3Target
    public let key: String

    public init(destinationID: String, target: S3Target, key: String) {
        self.destinationID = destinationID
        self.target = target
        self.key = key
    }
}
