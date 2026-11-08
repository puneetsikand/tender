import CryptoKit
import Foundation
import PhotoFerryCore

/// Finds out, against a real bucket, which integrity checks the service actually enforces.
enum S3Probe {
    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }

    static func line(_ ok: Bool?, _ text: String) {
        print("\(ok == nil ? "  ?" : ok! ? "  ✔" : "  ✘") \(text)")
    }

    static func run(_ s3: S3Client, prefix: String) async {
        print("0. list buckets (checks the key and secret, independent of the bucket name)")
        do {
            let names = try await s3.listBuckets()
            line(true, "key accepted; visible buckets: \(names.joined(separator: ", "))")
            guard names.contains(s3.endpoint.bucket) else {
                line(false, "bucket \(s3.endpoint.bucket) isn't among them; stopping")
                return
            }
        } catch let e as S3Error where e.code == "AccessDenied" {
            // The signature was accepted; the key just may not list buckets (normal for bucket-restricted keys).
            line(true, "key and secret accepted (this key may not list buckets: \(e.message))")
        } catch {
            line(false, "\(error)")
            print("  stopping: the key or secret isn't accepted, so the integrity tests would mean nothing")
            return
        }
        let stamp = Int(Date().timeIntervalSince1970)
        var body = Data(count: 256 * 1024)
        body.withUnsafeMutableBytes { for i in 0..<$0.count { $0[i] = UInt8(truncatingIfNeeded: i &* 131 &+ stamp) } }
        let md5 = hex(Insecure.MD5.hash(data: body))

        print("1. single PUT, correct SHA-256 signed")
        var baselineOK = false
        do {
            let r = try await s3.put("\(prefix)probe-\(stamp)-ok.bin", body: body)
            line(true, "accepted; ETag \(r.etag ?? "-") version \(r.versionID ?? "-")")
            baselineOK = true
            line(r.etag == md5, "ETag \(r.etag == md5 ? "equals" : "does NOT equal") the body's MD5")
            let h = try await s3.head("\(prefix)probe-\(stamp)-ok.bin")
            line(h?.size == Int64(body.count), "HEAD size \(h?.size ?? -1) (expected \(body.count))")
        } catch { line(false, "\(error)") }

        print("2. single PUT, WRONG SHA-256 signed (body corrupted in transit, as far as the server can tell)")
        do {
            let wrong = hex(SHA256.hash(data: Data("not the body".utf8)))
            _ = try await s3.put("\(prefix)probe-\(stamp)-bad.bin", body: body, signedPayloadHash: wrong)
            line(false, "ACCEPTED: the server does not verify the signed payload hash")
        } catch let e as S3Error {
            // Only meaningful if the correct upload in step 1 went through.
            line(baselineOK ? true : nil, "rejected: \(e.status) \(e.code) (\(e.message))\(baselineOK ? "" : " (inconclusive: step 1 failed)")")
        } catch { line(nil, "\(error)") }

        print("3. multipart: 2 parts with correct hashes, then complete")
        let key = "\(prefix)probe-\(stamp)-multi.bin"
        var big = Data(count: 5 * 1024 * 1024 + 300_000)
        big.withUnsafeMutableBytes { for i in stride(from: 0, to: $0.count, by: 4096) { $0[i] = UInt8(truncatingIfNeeded: i >> 12) } }
        let p1 = big.prefix(5 * 1024 * 1024), p2 = big.suffix(from: 5 * 1024 * 1024)
        do {
            let id = try await s3.createMultipartUpload(key)
            let e1 = try await s3.uploadPart(key, uploadID: id, partNumber: 1, body: Data(p1))
            let e2 = try await s3.uploadPart(key, uploadID: id, partNumber: 2, body: Data(p2))
            line(e1 == hex(Insecure.MD5.hash(data: Data(p1))), "part 1 ETag \(e1 == hex(Insecure.MD5.hash(data: Data(p1))) ? "equals" : "does NOT equal") its MD5")
            let r = try await s3.completeMultipartUpload(key, uploadID: id, parts: [(1, e1), (2, e2)])
            line(true, "completed; ETag \(r.etag ?? "-")")
            let h = try await s3.head(key)
            line(h?.size == Int64(big.count), "HEAD size \(h?.size ?? -1) (expected \(big.count))")
        } catch { line(false, "\(error)") }

        print("4. multipart part with WRONG SHA-256 signed")
        do {
            let id = try await s3.createMultipartUpload("\(prefix)probe-\(stamp)-multi-bad.bin")
            do {
                _ = try await s3.uploadPart("\(prefix)probe-\(stamp)-multi-bad.bin", uploadID: id, partNumber: 1, body: Data(p1),
                                            signedPayloadHash: hex(SHA256.hash(data: Data("nope".utf8))))
                line(false, "ACCEPTED: parts aren't checked against the signed hash")
            } catch let e as S3Error {
                line(true, "rejected: \(e.status) \(e.code) (\(e.message))")
            }
            try? await s3.abortMultipartUpload("\(prefix)probe-\(stamp)-multi-bad.bin", uploadID: id)
        } catch { line(nil, "\(error)") }
    }
}
