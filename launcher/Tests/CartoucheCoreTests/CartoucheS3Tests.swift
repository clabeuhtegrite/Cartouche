import XCTest
@testable import CartoucheCore

final class CartoucheS3Tests: XCTestCase {
    // The examples of AWS's documentation of Signature Version 4 for S3
    // ("Signature Calculations for the Authorization Header: Transferring
    // Payload in a Single Chunk"), with its example keys.
    private let signer = CartoucheS3Signer(
        accessKey: "AKIAIOSFODNN7EXAMPLE",
        secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1"
    )
    private let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z
    private var bucket: CartoucheS3Bucket {
        CartoucheS3Bucket(endpoint: CartoucheS3Endpoint.parse("s3.amazonaws.com")!, name: "examplebucket", region: "us-east-1")
    }

    func testAWSExampleGetObject() throws {
        XCTAssertEqual(bucket.authority, "examplebucket.s3.amazonaws.com")
        XCTAssertEqual(bucket.path("test.txt"), "/test.txt")
        let headers = signer.sign(method: "GET", authority: bucket.authority, path: bucket.path("test.txt"),
                                  headers: ["Range": "bytes=0-9"], date: date)
        XCTAssertEqual(headers["x-amz-date"], "20130524T000000Z")
        XCTAssertEqual(headers["x-amz-content-sha256"], CartoucheS3Signer.emptyPayloadHash)
        XCTAssertEqual(headers["Range"], "bytes=0-9")
        XCTAssertEqual(
            headers["Authorization"],
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
                + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
                + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
    }

    func testAWSExampleListObjects() throws {
        let query = [("prefix", "J"), ("max-keys", "2")]
        let headers = signer.sign(method: "GET", authority: bucket.authority, path: bucket.path(""),
                                  query: query, date: date)
        XCTAssertEqual(
            headers["Authorization"],
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
                + "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                + "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
        )
        XCTAssertEqual(bucket.url("", query: query)?.absoluteString, "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")
    }

    func testEncoding() {
        XCTAssertEqual(CartoucheS3Signer.encode("Jeux/Mario Kart [0400].ipa", keepingSlashes: true), "Jeux/Mario%20Kart%20%5B0400%5D.ipa")
        XCTAssertEqual(CartoucheS3Signer.encode("a/b+c~d", keepingSlashes: false), "a%2Fb%2Bc~d")
        XCTAssertEqual(CartoucheS3Signer.encode("é", keepingSlashes: false), "%C3%A9")
        XCTAssertEqual(CartoucheS3Signer.canonicalQuery([("uploads", ""), ("b", "2"), ("a", "1")]), "a=1&b=2&uploads=")
        XCTAssertEqual(CartoucheS3Signer.hash(Data()), CartoucheS3Signer.emptyPayloadHash)
    }

    func testEndpoints() throws {
        let nas = try XCTUnwrap(CartoucheS3Endpoint.parse(" http://192.168.1.2:9000/ "))
        XCTAssertEqual(nas, CartoucheS3Endpoint(secure: false, host: "192.168.1.2", port: 9000))
        XCTAssertEqual(nas.text, "http://192.168.1.2:9000")
        XCTAssertFalse(nas.isAWS)
        XCTAssertNil(nas.awsRegion)

        let minio = try XCTUnwrap(CartoucheS3Endpoint.parse("https://MinIO.example.com:443"))
        XCTAssertEqual(minio.authority, "minio.example.com")
        XCTAssertEqual(minio.text, "minio.example.com")

        XCTAssertEqual(CartoucheS3Endpoint.parse("s3.eu-west-3.amazonaws.com")?.awsRegion, "eu-west-3")
        XCTAssertEqual(CartoucheS3Endpoint.parse("s3-eu-west-1.amazonaws.com")?.awsRegion, "eu-west-1")
        XCTAssertEqual(CartoucheS3Endpoint.parse("s3.dualstack.ap-south-1.amazonaws.com")?.awsRegion, "ap-south-1")
        XCTAssertNil(CartoucheS3Endpoint.parse("s3.amazonaws.com")?.awsRegion)
        XCTAssertEqual(CartoucheS3Endpoint.parse("[::1]:9000")?.authority, "[::1]:9000")

        for refused in ["", "https://", "nas/bucket", "user@nas", "nas?x=1", "nas:0", "my nas"] {
            XCTAssertNil(CartoucheS3Endpoint.parse(refused), refused)
        }
    }

    func testPathStyleBuckets() throws {
        let nas = CartoucheS3Bucket(endpoint: CartoucheS3Endpoint.parse("http://nas.local:9000")!, name: "switch", region: "us-east-1")
        XCTAssertFalse(nas.isVirtualHosted)
        XCTAssertEqual(nas.authority, "nas.local:9000")
        XCTAssertEqual(nas.path(""), "/switch")
        XCTAssertEqual(nas.url("Jeux/a b.ipa", query: [("partNumber", "1"), ("uploadId", "x/y")])?.absoluteString,
                       "http://nas.local:9000/switch/Jeux/a%20b.ipa?partNumber=1&uploadId=x%2Fy")
        // A dot in the name is not covered by Amazon's certificate.
        let dotted = CartoucheS3Bucket(endpoint: CartoucheS3Endpoint.parse("s3.eu-west-3.amazonaws.com")!, name: "my.games", region: "eu-west-3")
        XCTAssertFalse(dotted.isVirtualHosted)
        XCTAssertEqual(dotted.url("x")?.absoluteString, "https://s3.eu-west-3.amazonaws.com/my.games/x")
    }

    func testListing() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>switch</Name><Prefix>Jeux/</Prefix><KeyCount>3</KeyCount>
          <IsTruncated>true</IsTruncated><NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken>
          <Contents><Key>Jeux/</Key><Size>0</Size><LastModified>2026-11-06T19:43:00.000Z</LastModified></Contents>
          <Contents><Key>Jeux/Mario Kart World &amp; co.ipa</Key><Size>5368709120</Size><LastModified>2026-11-06T19:43:12.000Z</LastModified><ETag>"abc"</ETag></Contents>
          <CommonPrefixes><Prefix>Jeux/Anciens/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let listing = try XCTUnwrap(CartoucheS3Listing.parse(Data(xml.utf8)))
        XCTAssertEqual(listing.objects.map(\.key), ["Jeux/", "Jeux/Mario Kart World & co.ipa"])
        XCTAssertEqual(listing.objects[1].size, 5_368_709_120)
        XCTAssertEqual(listing.objects[1].modified, Date(timeIntervalSince1970: 1_793_994_192))
        XCTAssertEqual(listing.prefixes, ["Jeux/Anciens/"])
        XCTAssertEqual(listing.next, "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")

        let last = try XCTUnwrap(CartoucheS3Listing.parse(Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8)))
        XCTAssertEqual(last, CartoucheS3Listing())
        XCTAssertNil(CartoucheS3Listing.parse(Data("<Error/>".utf8)))
    }

    func testFailures() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>AuthorizationHeaderMalformed</Code><Message>The authorization header is malformed; the region 'us-east-1' is wrong; expecting 'eu-west-3'</Message><Region>eu-west-3</Region></Error>
        """
        let wrongRegion = CartoucheS3Failure.parse(Data(xml.utf8), status: 400)
        XCTAssertEqual(wrongRegion.code, "AuthorizationHeaderMalformed")
        XCTAssertEqual(wrongRegion.region, "eu-west-3")
        XCTAssertFalse(wrongRegion.isRefusal)

        let head = CartoucheS3Failure.parse(Data(), status: 403)
        XCTAssertEqual(head.code, "AccessDenied")
        XCTAssertTrue(head.isRefusal)
        XCTAssertEqual(head.errorDescription, "AccessDenied")
        XCTAssertTrue(CartoucheS3Failure.parse(Data(), status: 404).isNotFound)
        XCTAssertEqual(CartoucheS3Failure.parse(Data(), status: 301, regionHeader: "eu-west-3").region, "eu-west-3")
    }

    func testMultipart() throws {
        let initiated = """
        <InitiateMultipartUploadResult><Bucket>switch</Bucket><Key>a.ipa</Key><UploadId>VXBsb2FkIElE</UploadId></InitiateMultipartUploadResult>
        """
        XCTAssertEqual(CartoucheS3Multipart.uploadID(Data(initiated.utf8)), "VXBsb2FkIElE")
        XCTAssertEqual(
            String(decoding: CartoucheS3Multipart.completion(["\"a1\"", "\"b2\""]), as: UTF8.self),
            "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
                + "<Part><PartNumber>1</PartNumber><ETag>&quot;a1&quot;</ETag></Part>"
                + "<Part><PartNumber>2</PartNumber><ETag>&quot;b2&quot;</ETag></Part>"
                + "</CompleteMultipartUpload>"
        )
    }

    func testReadAheadKeepsAChunk() async throws {
        let file = Data((0 ..< 100).map { UInt8($0) })
        var fetches: [(UInt64, Int)] = []
        let source = CartoucheReadAhead(size: UInt64(file.count), chunk: 32) { offset, count in
            fetches.append((offset, count))
            let start = Int(offset)
            return file.subdata(in: start ..< min(file.count, start + count))
        }
        let first = try await source.read(at: 10, count: 4)
        XCTAssertEqual(first, Data([10, 11, 12, 13]))
        let inside = try await source.read(at: 30, count: 12)
        XCTAssertEqual(inside, file.subdata(in: 30 ..< 42))
        let second = try await source.read(at: 40, count: 12)
        XCTAssertEqual(second, file.subdata(in: 40 ..< 52))
        let kept = try await source.read(at: 45, count: 7)
        XCTAssertEqual(kept, file.subdata(in: 45 ..< 52))
        let large = try await source.read(at: 0, count: 50)
        XCTAssertEqual(large, file.subdata(in: 0 ..< 50))
        let end = try await source.read(at: 90, count: 50)
        XCTAssertEqual(end, file.subdata(in: 90 ..< 100))
        let past = try await source.read(at: 100, count: 1)
        XCTAssertEqual(past, Data())
        XCTAssertEqual(fetches.map { $0.0 }, [10, 40, 0, 90])
        XCTAssertEqual(fetches.map { $0.1 }, [32, 32, 50, 10])
    }
}
