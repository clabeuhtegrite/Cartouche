//
//  CartoucheStorageS3.swift
//  Cartouche
//
//  A private S3 bucket of the player's, on Amazon S3 or on a server of
//  their own (MinIO on a NAS, for instance), reached with their own keys:
//  every request is signed with them (CartoucheS3.swift), and none is sent
//  without them. Paths are keys from the bucket's root, with "/" between
//  "folders", as S3 consoles show them.
//

import Foundation

final class CartoucheS3: CartoucheRemote {
    private var bucket: CartoucheS3Bucket
    private let accessKey: String
    private let secretKey: String
    private let session: URLSession

    private init(bucket: CartoucheS3Bucket, accessKey: String, secretKey: String) {
        self.bucket = bucket
        self.accessKey = accessKey
        self.secretKey = secretKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// SERVER's bucket, as its fields say: the address in host, the bucket
    /// in share, the access key ID in username, and the region, when the
    /// player gave one.
    static func target(of server: CartoucheStorageServer) throws -> CartoucheS3Bucket {
        guard let endpoint = CartoucheS3Endpoint.parse(server.host) else {
            throw CartoucheStorageError(.badAddress, CartoucheText.storageS3BadAddress)
        }
        let name = server.share.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else {
            throw CartoucheStorageError(.badBucket, CartoucheText.storageS3BadBucket)
        }
        let region = (server.region ?? "").trimmingCharacters(in: .whitespaces)
        return CartoucheS3Bucket(endpoint: endpoint, name: name,
                                 region: region.isEmpty ? CartoucheS3Bucket.defaultRegion(for: endpoint) : region)
    }

    /// Signs in to SERVER's bucket with the player's keys: the bucket must
    /// list for them.
    static func connect(_ server: CartoucheStorageServer, secretKey: String) async throws -> CartoucheS3 {
        let bucket = try target(of: server)
        let accessKey = server.username.trimmingCharacters(in: .whitespaces)
        // Only with the player's keys: never a public bucket.
        guard !accessKey.isEmpty, !secretKey.isEmpty else {
            throw CartoucheStorageError(.keysNeeded, CartoucheText.storageS3KeysNeeded)
        }
        // A server that takes no connection is out of reach from here, as a
        // NAS at home is from elsewhere: said within the reach patience,
        // rather than once a request has waited a minute.
        guard await CartoucheStorageReach.answers(server) else {
            throw CartoucheStorageOffline(server)
        }
        let remote = CartoucheS3(bucket: bucket, accessKey: accessKey, secretKey: secretKey)
        do {
            _ = try await remote.listPage(prefix: "", delimiter: "/", token: nil, most: 1)
        } catch let failure as URLError where offlineCodes.contains(failure.code) {
            throw CartoucheStorageOffline(server)
        } catch {
            throw CartoucheStorageError(.signInFailed, CartoucheText.storageSignInFailed(bucket.endpoint.host, error.localizedDescription), underlying: error)
        }
        return remote
    }

    /// What URLSession says when it finds no way to the server: no network,
    /// no address for its name, no connection.
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
        .internationalRoamingOff, .dataNotAllowed,
    ]

    // MARK: Requests

    /// Sends a request for KEY, signed, and gives S3's answer, or throws
    /// what S3 said went wrong. When S3 says the bucket is in another region
    /// than the one Cartouche signed for, it signs for that one, once.
    private func send(_ method: String, key: String, query: [(String, String)] = [],
                      headers: [String: String] = [:], body: Data? = nil,
                      retrying: Bool = true) async throws -> (Data, HTTPURLResponse) {
        guard let url = bucket.url(key, query: query) else {
            throw CartoucheStorageError(.badAddress, CartoucheText.storageS3BadAddress)
        }
        let signer = CartoucheS3Signer(accessKey: accessKey, secretKey: secretKey, region: bucket.region)
        let signed = signer.sign(method: method, authority: bucket.authority, path: bucket.path(key), query: query,
                                 headers: headers,
                                 payloadHash: body.map(CartoucheS3Signer.hash) ?? CartoucheS3Signer.emptyPayloadHash)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = method
        for (name, value) in signed {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // The bytes as they are kept, for the ranges to fall right.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response): (Data, URLResponse)
        if let body {
            (data, response) = try await session.upload(for: request, from: body)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CartoucheStorageError(.badAnswer, CartoucheText.storageS3BadAnswer)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let failure = CartoucheS3Failure.parse(data, status: http.statusCode,
                                                   regionHeader: http.value(forHTTPHeaderField: "x-amz-bucket-region"))
            if retrying, let region = failure.region, !region.isEmpty, region != bucket.region,
               [301, 400].contains(failure.status) {
                bucket.region = region
                return try await send(method, key: key, query: query, headers: headers, body: body, retrying: false)
            }
            throw failure
        }
        return (data, http)
    }

    private func listPage(prefix: String, delimiter: String?, token: String?, most: Int? = nil) async throws -> CartoucheS3Listing {
        var query = [("list-type", "2"), ("prefix", prefix)]
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let token { query.append(("continuation-token", token)) }
        if let most { query.append(("max-keys", String(most))) }
        let (data, _) = try await send("GET", key: "", query: query)
        guard let listing = CartoucheS3Listing.parse(data) else {
            throw CartoucheStorageError(.badAnswer, CartoucheText.storageS3BadAnswer)
        }
        return listing
    }

    /// Every object whose key starts with PREFIX, or, with a delimiter,
    /// those right in it and its "folders".
    private func listAll(prefix: String, delimiter: String?) async throws -> CartoucheS3Listing {
        var all = CartoucheS3Listing()
        var token: String?
        repeat {
            let page = try await listPage(prefix: prefix, delimiter: delimiter, token: token)
            all.objects += page.objects
            all.prefixes += page.prefixes
            token = page.next
        } while token != nil
        return all
    }

    /// PATH as the prefix of what is in it: "" for the bucket's root.
    private static func folderPrefix(_ path: String) -> String {
        let key = key(path)
        return key.isEmpty ? "" : key + "/"
    }

    private static func key(_ path: String) -> String {
        CartoucheStoragePath.join(path.precomposedStringWithCanonicalMapping)
    }

    // MARK: CartoucheRemote

    /// S3 says nothing of what a bucket lets an account do before it tries.
    var isReadOnly: Bool { false }

    func list(_ path: String) async throws -> [CartoucheRemoteItem] {
        let prefix = Self.folderPrefix(path)
        let listing = try await listAll(prefix: prefix, delimiter: "/")
        var items: [CartoucheRemoteItem] = []
        for folder in listing.prefixes {
            let name = String(folder.dropFirst(prefix.count).dropLast())
            guard !name.isEmpty, !name.hasPrefix(".") else { continue }
            items.append(CartoucheRemoteItem(name: name, isFolder: true, size: 0, modified: nil))
        }
        for object in listing.objects {
            let name = String(object.key.dropFirst(prefix.count))
            // The folder's own marker, which consoles make.
            guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { continue }
            items.append(CartoucheRemoteItem(name: name, isFolder: false, size: object.size, modified: object.modified))
        }
        return items
    }

    func open(_ path: String) async throws -> CartoucheByteSource {
        let key = Self.key(path)
        let (_, response) = try await send("HEAD", key: key)
        guard let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(UInt64.init) else {
            throw CartoucheStorageError(.badAnswer, CartoucheText.storageS3BadAnswer)
        }
        return CartoucheReadAhead(size: length) { [self] offset, count in
            let (data, response) = try await send("GET", key: key,
                                                  headers: ["Range": "bytes=\(offset)-\(offset + UInt64(count) - 1)"])
            // A server that ignores the range sends the whole file.
            if response.statusCode == 200 {
                let start = Int(offset)
                guard start < data.count else { return Data() }
                return data.subdata(in: start ..< min(data.count, start + count))
            }
            return data
        }
    }

    func create(_ path: String, size: UInt64?) async throws -> CartoucheRemoteUpload {
        S3Upload(remote: self, key: Self.key(path), size: size)
    }

    func makeFolder(_ path: String) async throws {
        _ = try await send("PUT", key: Self.folderPrefix(path), body: Data())
    }

    func delete(_ path: String) async throws {
        let key = Self.key(path)
        guard !key.isEmpty else { return }
        // A folder is every key under it.
        let inside = try await listAll(prefix: key + "/", delimiter: nil)
        for object in inside.objects {
            _ = try await send("DELETE", key: object.key)
        }
        _ = try await send("DELETE", key: key)
    }

    func freeSpace() async throws -> UInt64? {
        nil
    }

    func canWrite(_ path: String) async throws -> Bool {
        // S3 cannot be asked: Cartouche writes a hidden file, which no list
        // shows, and removes it.
        let probe = CartoucheStoragePath.join(Self.key(path), ".cartouche-write-check-" + UUID().uuidString)
        do {
            _ = try await send("PUT", key: probe, body: Data())
        } catch let failure as CartoucheS3Failure where failure.isRefusal {
            return false
        }
        _ = try? await send("DELETE", key: probe)
        return true
    }

    func disconnect() async {
        session.finishTasksAndInvalidate()
    }

    // MARK: Writing a file

    fileprivate func upload(_ key: String, _ data: Data) async throws {
        _ = try await send("PUT", key: key, body: data)
    }

    fileprivate func startUpload(_ key: String) async throws -> String {
        let (data, _) = try await send("POST", key: key, query: [("uploads", "")])
        guard let id = CartoucheS3Multipart.uploadID(data) else {
            throw CartoucheStorageError(.badAnswer, CartoucheText.storageS3BadAnswer)
        }
        return id
    }

    fileprivate func uploadPart(_ key: String, id: String, number: Int, _ data: Data) async throws -> String {
        let (_, response) = try await send("PUT", key: key, query: [("partNumber", String(number)), ("uploadId", id)], body: data)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw CartoucheStorageError(.badAnswer, CartoucheText.storageS3BadAnswer)
        }
        return etag
    }

    fileprivate func finishUpload(_ key: String, id: String, etags: [String]) async throws {
        let (data, _) = try await send("POST", key: key, query: [("uploadId", id)],
                                       headers: ["Content-Type": "application/xml"],
                                       body: CartoucheS3Multipart.completion(etags))
        // S3 may answer 200 with an error, once it has worked on the parts.
        if let root = CartoucheS3XML.parse(data), root.name == "Error" {
            throw CartoucheS3Failure.parse(data, status: 200)
        }
    }

    fileprivate func abortUpload(_ key: String, id: String) async {
        _ = try? await send("DELETE", key: key, query: [("uploadId", id)])
    }
}

/// A file being written to the bucket: in one request when it is small,
/// in parts otherwise, which S3 puts together only when Cartouche finishes,
/// so that the file there, if any, stays until then.
private final class S3Upload: CartoucheRemoteUpload {
    private let remote: CartoucheS3
    private let key: String
    private let partSize: Int
    private var buffer = Data()
    private var id: String?
    private var etags: [String] = []

    init(remote: CartoucheS3, key: String, size: UInt64?) {
        self.remote = remote
        self.key = key
        // 16 MiB parts, larger for a file that would need more than S3's
        // 10,000.
        let least = 16 << 20
        if let size, size / UInt64(least) >= 9_000 {
            partSize = Int(size / 9_000) + 1
        } else {
            partSize = least
        }
    }

    func write(_ data: Data) async throws {
        buffer.append(data)
        while buffer.count >= partSize {
            let part = buffer.prefix(partSize)
            buffer = Data(buffer.dropFirst(partSize))
            try await send(Data(part))
        }
    }

    private func send(_ part: Data) async throws {
        if id == nil {
            id = try await remote.startUpload(key)
        }
        guard let id else { return }
        let etag = try await remote.uploadPart(key, id: id, number: etags.count + 1, part)
        etags.append(etag)
    }

    func finish() async throws {
        if id == nil {
            try await remote.upload(key, buffer)
        } else {
            if !buffer.isEmpty {
                try await send(buffer)
            }
            if let id {
                try await remote.finishUpload(key, id: id, etags: etags)
            }
        }
        buffer = Data()
    }

    func cancel() async {
        buffer = Data()
        if let id {
            self.id = nil
            await remote.abortUpload(key, id: id)
        }
    }
}
