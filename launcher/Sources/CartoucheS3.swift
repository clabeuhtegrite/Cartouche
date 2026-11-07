//
//  CartoucheS3.swift
//  Cartouche
//
//  What Cartouche needs to reach an S3 bucket of the player's, without the
//  network: the address of their server, the AWS Signature Version 4 that
//  signs each request with their own keys, and the XML answers S3 gives.
//  CartoucheStorageS3.swift sends the requests.
//
//  Only a private bucket, with the player's keys: every request is signed,
//  and Cartouche has no way to reach a bucket without keys, nor a link to a
//  public one.
//

import CryptoKit
import Foundation

/// Where the player's S3 server is: Amazon S3, or one of their own, such as
/// MinIO on their NAS.
struct CartoucheS3Endpoint: Hashable {
    /// Whether requests go over HTTPS: always, unless the player typed
    /// http:// for a server on their own network.
    var secure: Bool
    /// Its name or address, in lower case, without brackets.
    var host: String
    var port: Int?

    /// TEXT as the player typed it: "s3.eu-west-3.amazonaws.com",
    /// "nas.local:9000", "https://minio.example.com" or
    /// "http://192.168.1.2:9000". Nil for what is not an address: a path, a
    /// query or an account in it.
    static func parse(_ text: String) -> CartoucheS3Endpoint? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var secure = true
        if rest.lowercased().hasPrefix("https://") {
            rest.removeFirst(8)
        } else if rest.lowercased().hasPrefix("http://") {
            rest.removeFirst(7)
            secure = false
        }
        while rest.hasSuffix("/") { rest.removeLast() }
        guard !rest.isEmpty, !rest.contains("/"), !rest.contains("@"), !rest.contains("?"), !rest.contains("#"),
              !rest.contains(where: \.isWhitespace),
              let components = URLComponents(string: "https://" + rest),
              var host = components.host, !host.isEmpty else { return nil }
        host = host.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        if let port = components.port, !(1 ... 65535).contains(port) { return nil }
        return CartoucheS3Endpoint(secure: secure, host: host, port: components.port)
    }

    /// The address as Cartouche shows and keeps it.
    var text: String {
        (secure ? "" : "http://") + authority
    }

    /// The host and the port the requests name, without the scheme's own
    /// port.
    var authority: String {
        let name = host.contains(":") ? "[" + host + "]" : host
        guard let port, port != (secure ? 443 : 80) else { return name }
        return name + ":" + String(port)
    }

    /// Whether this is Amazon S3 itself.
    var isAWS: Bool {
        host == "amazonaws.com" || host.hasSuffix(".amazonaws.com")
    }

    /// For Amazon S3, the region the address names: "eu-west-3" for
    /// s3.eu-west-3.amazonaws.com or s3-eu-west-3.amazonaws.com; nil for
    /// s3.amazonaws.com and other servers.
    var awsRegion: String? {
        guard isAWS else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard let s3 = labels.firstIndex(where: { $0 == "s3" || $0.hasPrefix("s3-") }) else { return nil }
        if labels[s3].hasPrefix("s3-") {
            let region = String(labels[s3].dropFirst(3))
            return region == "external-1" ? "us-east-1" : region
        }
        var next = s3 + 1
        if next < labels.count, labels[next] == "dualstack" { next += 1 }
        guard next < labels.count, labels[next] != "amazonaws" else { return nil }
        return labels[next]
    }
}

/// A bucket of the player's, on their server.
struct CartoucheS3Bucket: Hashable {
    var endpoint: CartoucheS3Endpoint
    var name: String
    var region: String

    /// The region to sign for when the player gave none: the one the address
    /// names, or us-east-1, which MinIO and most servers of one's own expect.
    static func defaultRegion(for endpoint: CartoucheS3Endpoint) -> String {
        endpoint.awsRegion ?? "us-east-1"
    }

    /// Amazon S3 names a bucket in the host (bucket.s3.amazonaws.com);
    /// other servers, and a bucket with a dot, which a certificate for
    /// *.s3.amazonaws.com does not cover, in the path.
    var isVirtualHosted: Bool {
        endpoint.isAWS && !name.contains(".")
    }

    /// The host the request for KEY goes to, with its port.
    var authority: String {
        isVirtualHosted ? name + "." + endpoint.authority : endpoint.authority
    }

    /// The path of KEY, encoded as S3 signs it; "/" for the bucket itself
    /// on Amazon S3.
    func path(_ key: String) -> String {
        let encoded = CartoucheS3Signer.encode(key, keepingSlashes: true)
        return isVirtualHosted ? "/" + encoded : "/" + CartoucheS3Signer.encode(name, keepingSlashes: false) + (key.isEmpty ? "" : "/" + encoded)
    }

    /// The URL of KEY, with QUERY, encoded as S3 signs it.
    func url(_ key: String, query: [(String, String)] = []) -> URL? {
        let encodedQuery = CartoucheS3Signer.canonicalQuery(query)
        return URL(string: (endpoint.secure ? "https://" : "http://") + authority + path(key)
            + (encodedQuery.isEmpty ? "" : "?" + encodedQuery))
    }
}

/// AWS Signature Version 4, for S3, with the player's keys.
struct CartoucheS3Signer {
    var accessKey: String
    var secretKey: String
    var region: String
    var service = "s3"

    /// The SHA-256 of nothing, for a request without a body.
    static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    static func hash(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// TEXT encoded as AWS's UriEncode does: every byte but A-Z, a-z, 0-9,
    /// "-", ".", "_" and "~" as %XX, and "/" too unless KEEPINGSLASHES.
    static func encode(_ text: String, keepingSlashes: Bool) -> String {
        var encoded = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                encoded.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: "/") where keepingSlashes:
                encoded.append("/")
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    /// QUERY as S3 signs it, and as the URL carries it: each name and value
    /// encoded, sorted by name, then by value.
    static func canonicalQuery(_ query: [(String, String)]) -> String {
        query.map { (encode($0.0, keepingSlashes: false), encode($0.1, keepingSlashes: false)) }
            .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { $0.0 + "=" + $0.1 }
            .joined(separator: "&")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    /// The headers to send with a request: HEADERS, x-amz-date,
    /// x-amz-content-sha256 and Authorization, which signs them all and the
    /// host. PATH is encoded, as CartoucheS3Bucket.path gives it.
    func sign(method: String, authority: String, path: String, query: [(String, String)] = [],
              headers: [String: String] = [:], payloadHash: String = CartoucheS3Signer.emptyPayloadHash,
              date: Date = Date()) -> [String: String] {
        let amzDate = Self.dateFormatter.string(from: date)
        let day = String(amzDate.prefix(8))
        var signed: [String: String] = [:]
        for (name, value) in headers {
            signed[name.lowercased()] = value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        signed["host"] = authority
        signed["x-amz-date"] = amzDate
        signed["x-amz-content-sha256"] = payloadHash
        let names = signed.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalHeaders = names.map { $0 + ":" + (signed[$0] ?? "") + "\n" }.joined()
        let canonicalRequest = [
            method,
            path.isEmpty ? "/" : path,
            Self.canonicalQuery(query),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = day + "/" + region + "/" + service + "/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.hash(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
        var key = SymmetricKey(data: Data(("AWS4" + secretKey).utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        var sent = headers
        sent["x-amz-date"] = amzDate
        sent["x-amz-content-sha256"] = payloadHash
        sent["Authorization"] = "AWS4-HMAC-SHA256 Credential=" + accessKey + "/" + scope
            + ", SignedHeaders=" + signedHeaders + ", Signature=" + signature
        return sent
    }
}

// MARK: S3's answers

/// An XML answer of S3, as a tree.
final class CartoucheS3XML {
    let name: String
    fileprivate(set) var text = ""
    fileprivate(set) var children: [CartoucheS3XML] = []

    init(name: String) {
        self.name = name
    }

    /// DATA's root element; nil when it is not XML.
    static func parse(_ data: Data) -> CartoucheS3XML? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    func child(_ name: String) -> CartoucheS3XML? {
        children.first { $0.name == name }
    }

    func all(_ name: String) -> [CartoucheS3XML] {
        children.filter { $0.name == name }
    }

    /// The text of the child NAME.
    subscript(_ name: String) -> String? {
        child(name)?.text
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: CartoucheS3XML?
        private var open: [CartoucheS3XML] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let element = CartoucheS3XML(name: elementName)
            if let parent = open.last {
                parent.children.append(element)
            } else if root == nil {
                root = element
            }
            open.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            open.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = open.popLast()
        }
    }
}

/// An object in a bucket, as a listing gives it.
struct CartoucheS3Object: Hashable {
    let key: String
    let size: UInt64
    let modified: Date?
}

/// One page of a ListObjectsV2 answer.
struct CartoucheS3Listing: Hashable {
    var objects: [CartoucheS3Object] = []
    /// The "folders": the keys' parts up to the delimiter, with it.
    var prefixes: [String] = []
    /// The token of the next page, when there is one.
    var next: String?

    static func parse(_ data: Data) -> CartoucheS3Listing? {
        guard let root = CartoucheS3XML.parse(data), root.name == "ListBucketResult" else { return nil }
        var listing = CartoucheS3Listing()
        for contents in root.all("Contents") {
            guard let key = contents["Key"] else { continue }
            listing.objects.append(CartoucheS3Object(
                key: key,
                size: UInt64(contents["Size"] ?? "") ?? 0,
                modified: contents["LastModified"].flatMap(date)
            ))
        }
        listing.prefixes = root.all("CommonPrefixes").compactMap { $0["Prefix"] }
        if root["IsTruncated"] == "true", let next = root["NextContinuationToken"], !next.isEmpty {
            listing.next = next
        }
        return listing
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// What S3 says went wrong.
struct CartoucheS3Failure: LocalizedError, Hashable {
    let status: Int
    /// "AccessDenied", "NoSuchBucket", "SignatureDoesNotMatch"…
    let code: String
    let message: String
    /// The bucket's region, when S3 says it is not the one Cartouche signed
    /// for.
    let region: String?

    var errorDescription: String? {
        message.isEmpty ? (code.isEmpty ? "HTTP \(status)" : code) : message
    }

    /// The answer DATA, with STATUS, which may have no XML: a HEAD has none.
    static func parse(_ data: Data, status: Int, regionHeader: String? = nil) -> CartoucheS3Failure {
        let root = CartoucheS3XML.parse(data)
        let error = root?.name == "Error" ? root : nil
        let code = error?["Code"] ?? Self.code(for: status)
        return CartoucheS3Failure(
            status: status,
            code: code,
            message: error?["Message"] ?? "",
            region: regionHeader ?? error?["Region"]
        )
    }

    private static func code(for status: Int) -> String {
        switch status {
        case 301: return "PermanentRedirect"
        case 403: return "AccessDenied"
        case 404: return "NotFound"
        default: return ""
        }
    }

    var isNotFound: Bool {
        status == 404
    }

    var isRefusal: Bool {
        status == 403 || code == "AccessDenied"
    }
}

/// The body of a CompleteMultipartUpload, with the parts' ETags in order.
enum CartoucheS3Multipart {
    static func uploadID(_ data: Data) -> String? {
        guard let root = CartoucheS3XML.parse(data), root.name == "InitiateMultipartUploadResult" else { return nil }
        return root["UploadId"]
    }

    static func completion(_ etags: [String]) -> Data {
        var xml = "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        for (index, etag) in etags.enumerated() {
            xml += "<Part><PartNumber>\(index + 1)</PartNumber><ETag>" + escape(etag) + "</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        return Data(xml.utf8)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: Reading a file

/// A file read with one request for each part asked: it asks for at least
/// CHUNK bytes at once and keeps them, so that the many small reads of an
/// IPA's entries do not each wait for the server.
final class CartoucheReadAhead: CartoucheByteSource {
    let size: UInt64
    private let chunk: Int
    private let fetch: (UInt64, Int) async throws -> Data
    private var kept = Data()
    private var keptAt: UInt64 = 0

    /// FETCH reads COUNT bytes at an offset, all of them unless the file
    /// ends first.
    init(size: UInt64, chunk: Int = 4 << 20, fetch: @escaping (UInt64, Int) async throws -> Data) {
        self.size = size
        self.chunk = chunk
        self.fetch = fetch
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let wanted = Int(min(UInt64(count), size - offset))
        if offset >= keptAt, offset + UInt64(wanted) <= keptAt + UInt64(kept.count) {
            let start = kept.startIndex + Int(offset - keptAt)
            return kept.subdata(in: start ..< start + wanted)
        }
        if wanted >= chunk {
            return try await fetch(offset, wanted)
        }
        let asked = Int(min(UInt64(chunk), size - offset))
        let data = try await fetch(offset, asked)
        kept = data
        keptAt = offset
        return data.prefix(wanted)
    }
}
