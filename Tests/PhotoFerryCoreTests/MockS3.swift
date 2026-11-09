import CryptoKit
import Foundation
import Synchronization
@testable import PhotoFerryCore

/// An in-memory S3 that behaves like B2 where it matters: it rejects a body whose SHA-256 doesn't
/// match the signed `x-amz-content-sha256` (400 IncompleteBody), supports multipart, and can be
/// told to fail. Requests to host `mock.s3.test` are routed here via `session`.
final class MockS3: URLProtocol, @unchecked Sendable {
    struct State {
        var objects: [String: Data] = [:]
        var uploads: [String: [Int: Data]] = [:]
        var nextUploadID = 1
        var failPartNumbers: Set<Int> = []      // these part uploads answer 500 (once each)
        var rejectAuth = false
        var requests: [String] = []
    }
    static let state = Mutex(State())

    static func reset() { state.withLock { $0 = State() } }

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockS3.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mock.s3.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    static func readBody(_ r: URLRequest) -> Data {
        if let d = r.httpBody { return d }
        guard let s = r.httpBodyStream else { return Data() }
        s.open(); defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
        return out
    }

    func reply(_ status: Int, headers: [String: String] = [:], body: String = "") {
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    func error(_ status: Int, _ code: String, _ msg: String) {
        reply(status, body: "<Error><Code>\(code)</Code><Message>\(msg)</Message></Error>")
    }

    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let key = String(url.path(percentEncoded: false).dropFirst())        // "bucket/key"
        let body = Self.readBody(request)
        Self.state.withLock { $0.requests.append("\(method) \(key) \(q.keys.sorted().joined(separator: ","))") }

        if Self.state.withLock({ $0.rejectAuth }) { return error(403, "AccessDenied", "not entitled") }
        if !body.isEmpty, request.value(forHTTPHeaderField: "x-amz-content-sha256") != Self.hex(SHA256.hash(data: body)) {
            return error(400, "IncompleteBody", "The request body was too small")       // what B2 answers
        }
        switch (method, q["uploads"] != nil, q["uploadId"], q["partNumber"]) {
        case ("PUT", false, nil, nil):
            Self.state.withLock { $0.objects[key] = body }
            reply(200, headers: ["ETag": "\"\(Self.hex(Insecure.MD5.hash(data: body)))\"", "x-amz-version-id": "v1"])
        case ("HEAD", _, _, _):
            if let d = Self.state.withLock({ $0.objects[key] }) { reply(200, headers: ["Content-Length": "\(d.count)"]) } else { reply(404) }
        case ("POST", true, _, _):
            let id = Self.state.withLock { s -> String in defer { s.nextUploadID += 1 }; s.uploads["u\(s.nextUploadID)"] = [:]; return "u\(s.nextUploadID)" }
            reply(200, body: "<InitiateMultipartUploadResult><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>")
        case ("PUT", _, let id?, let n?):
            let part = Int(n)!
            let outcome = Self.state.withLock { s -> Int in
                if s.failPartNumbers.remove(part) != nil { return 500 }
                guard s.uploads[id] != nil else { return 404 }
                s.uploads[id]![part] = body
                return 200
            }
            switch outcome {
            case 500: error(500, "InternalError", "injected failure")
            case 404: error(404, "NoSuchUpload", "no such upload")
            default: reply(200, headers: ["ETag": "\"\(Self.hex(Insecure.MD5.hash(data: body)))\""])
            }
        case ("POST", _, let id?, _):
            let ok = Self.state.withLock { s -> Bool in
                guard let parts = s.uploads.removeValue(forKey: id) else { return false }
                s.objects[key] = parts.sorted { $0.key < $1.key }.reduce(Data()) { $0 + $1.value }
                return true
            }
            ok ? reply(200, body: "<CompleteMultipartUploadResult><ETag>&quot;x-1&quot;</ETag></CompleteMultipartUploadResult>")
               : error(404, "NoSuchUpload", "no such upload")
        case ("DELETE", _, let id?, _):
            Self.state.withLock { _ = $0.uploads.removeValue(forKey: id) }
            reply(204)
        default:
            error(400, "NotImplemented", "\(method) \(url)")
        }
    }
}

