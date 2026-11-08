import Foundation
import Testing
@testable import PhotoFerryCore

@Suite struct SigV4Tests {
    /// AWS's published example ("GET Object", Signature V4 for S3): GET /test.txt with a Range header.
    @Test func matchesAWSPublishedGetObjectExample() {
        let signer = SigV4(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
        var r = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        r.httpMethod = "GET"
        r.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        r.setValue("20130524T000000Z", forHTTPHeaderField: "x-amz-date")
        r.setValue(SigV4.emptyPayloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        let auth = signer.authorization(for: r, payloadSHA256: SigV4.emptyPayloadHash, amzDate: "20130524T000000Z", day: "20130524")
        #expect(auth == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
                + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
                + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func encodesKeysAndQueriesTheS3Way() {
        let url = URL(string: "https://s3.us-east-005.backblazeb2.com/bucket/2026/2026-09-19/RAW/GFX%20R%2B1.RAF?uploads=")!
        #expect(SigV4.canonicalURI(url) == "/bucket/2026/2026-09-19/RAW/GFX%20R%2B1.RAF")
        #expect(SigV4.canonicalQuery(url) == "uploads=")
        let q = URL(string: "https://h/b/k?uploadId=a%2Fb&partNumber=2")!
        #expect(SigV4.canonicalQuery(q) == "partNumber=2&uploadId=a%2Fb")
    }

    @Test func regionComesFromTheEndpointHost() {
        #expect(S3Endpoint(host: "s3.us-east-005.backblazeb2.com", bucket: "b").region == "us-east-005")
        #expect(S3Endpoint(host: "s3.eu-west-1.amazonaws.com", bucket: "b").region == "eu-west-1")
        #expect(S3Endpoint(host: "minio.tailnet.ts.net", bucket: "b").region == "us-east-1")
    }
}
