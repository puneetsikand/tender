import CryptoKit
import Foundation
import Security

/// Where a bucket lives. Path-style URLs (`https://host/bucket/key`), which every
/// S3-compatible service accepts.
public struct S3Endpoint: Sendable, Hashable, Codable {
    public var host: String
    public var region: String
    public var bucket: String

    public init(host: String, region: String? = nil, bucket: String) {
        self.host = host
        self.region = region ?? Self.region(fromHost: host) ?? "us-east-1"
        self.bucket = bucket
    }

    /// `s3.us-east-005.backblazeb2.com` → `us-east-005`; `s3.eu-west-1.amazonaws.com` → `eu-west-1`.
    public static func region(fromHost host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count >= 3, parts[0] == "s3" else { return nil }
        return String(parts[1])
    }

    func url(for key: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/\(bucket)/\(key)"
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }
}

/// Access keys live only in the Keychain (service `local.photoferry.s3`, account = key ID).
/// Lookups always name the account, so another entry under the same service can't be picked up.
public enum S3Keychain {
    public static let service = "local.photoferry.s3"

    public enum Failure: Error, CustomStringConvertible {
        case notFound(String)
        case unreadable(OSStatus)
        public var description: String {
            switch self {
            case .notFound(let id): "no Keychain entry for key ID \(id) (service \(S3Keychain.service))"
            case .unreadable(let s): "Keychain read failed (\(s))"
            }
        }
    }

    public static func secret(forKeyID keyID: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keyID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { throw Failure.notFound(keyID) }
        guard status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) else {
            throw Failure.unreadable(status)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct S3Error: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let code: String
    public let message: String
    public var description: String { "S3 \(status) \(code): \(message)" }

    init(status: Int, body: Data) {
        self.status = status
        let text = String(decoding: body, as: UTF8.self)
        func tag(_ t: String) -> String? {
            guard let r = text.range(of: "<\(t)>"), let e = text.range(of: "</\(t)>", range: r.upperBound..<text.endIndex) else { return nil }
            return String(text[r.upperBound..<e.lowerBound])
        }
        code = tag("Code") ?? "HTTP\(status)"
        message = tag("Message") ?? text.prefix(200).description
    }
}

/// A minimal S3 client: exactly what offsite backup needs, over URLSession, no SDK.
public struct S3Client: Sendable {
    public let endpoint: S3Endpoint
    let signer: SigV4
    let session: URLSession

    public init(endpoint: S3Endpoint, keyID: String, secret: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        signer = SigV4(accessKeyID: keyID, secret: secret, region: endpoint.region)
        self.session = session
    }

    /// Reads the secret from the Keychain.
    public init(endpoint: S3Endpoint, keyID: String) throws {
        self.init(endpoint: endpoint, keyID: keyID, secret: try S3Keychain.secret(forKeyID: keyID))
    }

    public struct PutResult: Sendable, Hashable {
        public let etag: String?
        public let versionID: String?
    }

    public struct HeadResult: Sendable, Hashable {
        public let size: Int64
        public let etag: String?
    }

    /// Uploads `body` with its SHA-256 signed as the payload hash. `signedPayloadHash` exists for
    /// tests that deliberately sign a wrong hash.
    public func put(_ key: String, body: Data, contentType: String = "application/octet-stream",
                    signedPayloadHash: String? = nil) async throws -> PutResult {
        var r = URLRequest(url: endpoint.url(for: key))
        r.httpMethod = "PUT"
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        signer.sign(&r, payloadSHA256: signedPayloadHash ?? SigV4.hex(SHA256.hash(data: body)))
        let (data, resp) = try await session.upload(for: r, from: body)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else { throw S3Error(status: http.statusCode, body: data) }
        return PutResult(etag: http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                         versionID: http.value(forHTTPHeaderField: "x-amz-version-id"))
    }

    /// Uploads a file straight from disk; `sha256` is its known hash (from the card read).
    public func putFile(_ key: String, file: URL, sha256: String, contentType: String = "application/octet-stream") async throws -> PutResult {
        var r = URLRequest(url: endpoint.url(for: key))
        r.httpMethod = "PUT"
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        signer.sign(&r, payloadSHA256: sha256)
        let (data, resp) = try await session.upload(for: r, fromFile: file)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else { throw S3Error(status: http.statusCode, body: data) }
        return PutResult(etag: http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                         versionID: http.value(forHTTPHeaderField: "x-amz-version-id"))
    }

    public func head(_ key: String) async throws -> HeadResult? {
        var r = URLRequest(url: endpoint.url(for: key))
        r.httpMethod = "HEAD"
        signer.sign(&r, payloadSHA256: SigV4.emptyPayloadHash)
        let (data, resp) = try await session.data(for: r)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw S3Error(status: http.statusCode, body: data) }
        return HeadResult(size: Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1,
                          etag: http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    /// Bucket names this key can see (bucket-restricted B2 keys see just their bucket).
    public func listBuckets() async throws -> [String] {
        var c = URLComponents(); c.scheme = "https"; c.host = endpoint.host; c.path = "/"
        var r = URLRequest(url: c.url!)
        r.httpMethod = "GET"
        signer.sign(&r, payloadSHA256: SigV4.emptyPayloadHash)
        let (data, resp) = try await session.data(for: r)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else { throw S3Error(status: http.statusCode, body: data) }
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "<Name>").dropFirst().compactMap { $0.components(separatedBy: "</Name>").first }
    }

    // MARK: Multipart (files larger than one part; GFX RAFs are ~120 MB)

    public func createMultipartUpload(_ key: String, contentType: String = "application/octet-stream") async throws -> String {
        var r = URLRequest(url: endpoint.url(for: key, query: [URLQueryItem(name: "uploads", value: "")]))
        r.httpMethod = "POST"
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        signer.sign(&r, payloadSHA256: SigV4.emptyPayloadHash)
        let (data, resp) = try await session.data(for: r)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else { throw S3Error(status: http.statusCode, body: data) }
        let text = String(decoding: data, as: UTF8.self)
        guard let a = text.range(of: "<UploadId>"), let b = text.range(of: "</UploadId>") else {
            throw S3Error(status: http.statusCode, body: Data("no UploadId".utf8))
        }
        return String(text[a.upperBound..<b.lowerBound])
    }

    /// Uploads one part; its SHA-256 is signed. Returns the part's ETag.
    public func uploadPart(_ key: String, uploadID: String, partNumber: Int, body: Data, signedPayloadHash: String? = nil) async throws -> String {
        var r = URLRequest(url: endpoint.url(for: key, query: [URLQueryItem(name: "partNumber", value: String(partNumber)),
                                                               URLQueryItem(name: "uploadId", value: uploadID)]))
        r.httpMethod = "PUT"
        signer.sign(&r, payloadSHA256: signedPayloadHash ?? SigV4.hex(SHA256.hash(data: body)))
        let (data, resp) = try await session.upload(for: r, from: body)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else { throw S3Error(status: http.statusCode, body: data) }
        return http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
    }

    public func completeMultipartUpload(_ key: String, uploadID: String, parts: [(number: Int, etag: String)]) async throws -> PutResult {
        let xml = "<CompleteMultipartUpload>" + parts.map {
            "<Part><PartNumber>\($0.number)</PartNumber><ETag>\"\($0.etag)\"</ETag></Part>"
        }.joined() + "</CompleteMultipartUpload>"
        let body = Data(xml.utf8)
        var r = URLRequest(url: endpoint.url(for: key, query: [URLQueryItem(name: "uploadId", value: uploadID)]))
        r.httpMethod = "POST"
        r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        signer.sign(&r, payloadSHA256: SigV4.hex(SHA256.hash(data: body)))
        let (data, resp) = try await session.upload(for: r, from: body)
        let http = resp as! HTTPURLResponse
        // S3 can report a failed completion inside a 200 response.
        guard (200..<300).contains(http.statusCode), !String(decoding: data, as: UTF8.self).contains("<Error>") else {
            throw S3Error(status: http.statusCode, body: data)
        }
        return PutResult(etag: http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                         versionID: http.value(forHTTPHeaderField: "x-amz-version-id"))
    }

    public func abortMultipartUpload(_ key: String, uploadID: String) async throws {
        var r = URLRequest(url: endpoint.url(for: key, query: [URLQueryItem(name: "uploadId", value: uploadID)]))
        r.httpMethod = "DELETE"
        signer.sign(&r, payloadSHA256: SigV4.emptyPayloadHash)
        let (data, resp) = try await session.data(for: r)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) || http.statusCode == 404 else { throw S3Error(status: http.statusCode, body: data) }
    }
}
