import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3-compatible services (AWS, Backblaze B2, Wasabi, R2, MinIO).
///
/// The payload hash (`x-amz-content-sha256`) is part of what's signed. For uploads PhotoFerry
/// signs the real SHA-256 of the body, i.e. the hash it computed when reading the card, so a
/// server that checks it (AWS does; B2 is tested in CloudTests) rejects any body that changed in transit.
public struct SigV4: Sendable {
    public let accessKeyID: String
    let secret: String
    public let region: String
    public let service: String

    public init(accessKeyID: String, secret: String, region: String, service: String = "s3") {
        self.accessKeyID = accessKeyID
        self.secret = secret
        self.region = region
        self.service = service
    }

    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Signs a request: sets `x-amz-date`, `x-amz-content-sha256` and `Authorization`.
    /// Every header already on the request (plus `host`) is signed.
    public func sign(_ request: inout URLRequest, payloadSHA256 hex: String, date: Date = .now) {
        let amzDate = Self.amzDate(date)
        let day = String(amzDate.prefix(8))
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(hex, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(authorization(for: request, payloadSHA256: hex, amzDate: amzDate, day: day), forHTTPHeaderField: "Authorization")
    }

    func authorization(for request: URLRequest, payloadSHA256: String, amzDate: String, day: String) -> String {
        let url = request.url!
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] where k.lowercased() != "authorization" {
            headers[k.lowercased()] = v.trimmingCharacters(in: .whitespaces)
        }
        headers["host"] = url.port.map { "\(url.host!):\($0)" } ?? url.host!
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonicalRequest = [
            request.httpMethod ?? "GET",
            Self.canonicalURI(url),
            Self.canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadSHA256,
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))]
            .joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        return "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// RFC 3986 encoding of each path segment (S3 rules: no double encoding, keep '/').
    static func canonicalURI(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let segments = (path.isEmpty ? "/" : path).split(separator: "/", omittingEmptySubsequences: false)
        return segments.map { uriEncode(String($0)) }.joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return "" }
        let pairs: [(name: String, value: String)] = items.map { (uriEncode($0.name), uriEncode($0.value ?? "")) }
        let sorted = pairs.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    static func uriEncode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 {
        d.map { String(format: "%02x", $0) }.joined()
    }
}
