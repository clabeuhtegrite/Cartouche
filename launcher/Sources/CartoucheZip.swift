//
//  CartoucheZip.swift
//  Cartouche
//
//  Zip archives, which IPAs and Cartouche's save backups are, read and
//  written where they sit: on the player's storage, without a copy on the
//  iPhone first, since a game's IPA can be larger than the room the iPhone
//  has left.
//
//  - Reading takes the archive's central directory from its end, then its
//    entries in the order they lie, in one pass from start to end: the
//    storage serves long reads in order best. Each entry is checked against
//    its size and CRC-32. Only what an IPA holds is taken: folders, files,
//    stored or deflated, and links that stay inside the archive, with their
//    Unix modes; Zip64 for archives and files past 4 GiB, as nxnative's
//    pack_ipa.py makes them.
//  - Writing goes in order too, without going back: a file's CRC-32 is read
//    first, so that its local header is right at once, as pack_ipa.py's are.
//    Small files are deflated when that makes them smaller, large ones are
//    stored: a game's data is mostly compressed already, and deflating
//    gigabytes would take the iPhone longer than sending them.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Compression
import Foundation

/// A file read at any offset: on the player's storage, or on the iPhone.
protocol CartoucheByteSource: AnyObject {
    var size: UInt64 { get }
    /// COUNT bytes from OFFSET, fewer only at the end of the file.
    func read(at offset: UInt64, count: Int) async throws -> Data
}

/// A file written from start to end.
protocol CartoucheByteSink: AnyObject {
    func write(_ data: Data) async throws
}

struct CartoucheZipError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

/// An entry of an archive's central directory.
struct CartoucheZipEntry: Hashable {
    /// Its path in the archive, with "/" between folders.
    let name: String
    /// 0: stored, 8: deflated.
    let method: UInt16
    let crc: UInt32
    let compressedSize: UInt64
    let size: UInt64
    let localHeaderOffset: UInt64
    /// Its Unix mode and type, when the archive was made on a Unix system.
    let mode: UInt32?

    var isDirectory: Bool {
        if let mode, mode & 0o170000 != 0 { return mode & 0o170000 == 0o040000 }
        return name.hasSuffix("/")
    }

    var isSymlink: Bool {
        guard let mode else { return false }
        return mode & 0o170000 == 0o120000
    }
}

enum CartoucheZip {
    static let localSignature: UInt32 = 0x0403_4B50
    static let centralSignature: UInt32 = 0x0201_4B50
    static let endSignature: UInt32 = 0x0605_4B50
    static let end64Signature: UInt32 = 0x0606_4B50
    static let locator64Signature: UInt32 = 0x0706_4B50

    /// The archive's entries, from its central directory: two reads at its
    /// end, three for a Zip64 archive.
    static func entries(of source: CartoucheByteSource) async throws -> [CartoucheZipEntry] {
        let size = source.size
        guard size >= 22 else { throw CartoucheZipError("not a zip archive") }
        // The end record is the last 22 bytes, before a comment of up to
        // 65,535 bytes; a Zip64 locator of 20 bytes comes just before it.
        let tailCount = Int(min(size, 22 + 65_535 + 20))
        let tailStart = size - UInt64(tailCount)
        let tail = try await source.read(at: tailStart, count: tailCount)
        guard tail.count == tailCount else { throw CartoucheZipError("the archive ended early") }
        var endAt: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail.uint32(at: index) == endSignature, index + 22 + Int(tail.uint16(at: index + 20)) <= tail.count {
                endAt = index
                break
            }
            index -= 1
        }
        guard let endAt else { throw CartoucheZipError("not a zip archive") }

        var count = UInt64(tail.uint16(at: endAt + 10))
        var directorySize = UInt64(tail.uint32(at: endAt + 12))
        var directoryOffset = UInt64(tail.uint32(at: endAt + 16))
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            let locatorAt = endAt - 20
            guard locatorAt >= 0, tail.uint32(at: locatorAt) == locator64Signature else {
                throw CartoucheZipError("the Zip64 end record is missing")
            }
            let end64Offset = tail.uint64(at: locatorAt + 8)
            guard end64Offset < size else { throw CartoucheZipError("the Zip64 end record is out of the archive") }
            let end64 = try await source.read(at: end64Offset, count: 56)
            guard end64.count == 56, end64.uint32(at: 0) == end64Signature else {
                throw CartoucheZipError("the Zip64 end record is damaged")
            }
            count = end64.uint64(at: 32)
            directorySize = end64.uint64(at: 40)
            directoryOffset = end64.uint64(at: 48)
        }
        guard directoryOffset <= size, directorySize <= size - directoryOffset, directorySize < 1 << 30 else {
            throw CartoucheZipError("the central directory is out of the archive")
        }
        let directory = try await source.read(at: directoryOffset, count: Int(directorySize))
        guard directory.count == Int(directorySize) else { throw CartoucheZipError("the archive ended early") }
        return try parseDirectory(directory, count: count, archiveSize: size)
    }

    static func parseDirectory(_ directory: Data, count: UInt64, archiveSize: UInt64) throws -> [CartoucheZipEntry] {
        var entries: [CartoucheZipEntry] = []
        entries.reserveCapacity(Int(min(count, 1 << 20)))
        var at = 0
        while entries.count < count {
            guard at + 46 <= directory.count, directory.uint32(at: at) == centralSignature else {
                throw CartoucheZipError("the central directory is damaged")
            }
            let madeBy = directory.uint16(at: at + 4)
            let flags = directory.uint16(at: at + 8)
            let method = directory.uint16(at: at + 10)
            let crc = directory.uint32(at: at + 16)
            var compressedSize = UInt64(directory.uint32(at: at + 20))
            var size = UInt64(directory.uint32(at: at + 24))
            let nameLength = Int(directory.uint16(at: at + 28))
            let extraLength = Int(directory.uint16(at: at + 30))
            let commentLength = Int(directory.uint16(at: at + 32))
            let external = directory.uint32(at: at + 38)
            var offset = UInt64(directory.uint32(at: at + 42))
            let nameAt = at + 46
            let extraAt = nameAt + nameLength
            let next = extraAt + extraLength + commentLength
            guard next <= directory.count else { throw CartoucheZipError("the central directory is damaged") }
            let nameBytes = directory.subdata(in: directory.startIndex + nameAt ..< directory.startIndex + extraAt)
            // UTF-8, as flag 11 says or as most tools write it anyway.
            let name = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""

            // Zip64: the fields that did not fit, in this order.
            var extra = extraAt
            while extra + 4 <= extraAt + extraLength {
                let id = directory.uint16(at: extra)
                let length = Int(directory.uint16(at: extra + 2))
                let body = extra + 4
                guard body + length <= extraAt + extraLength else { break }
                if id == 0x0001 {
                    var field = body
                    if size == 0xFFFF_FFFF, field + 8 <= body + length {
                        size = directory.uint64(at: field)
                        field += 8
                    }
                    if compressedSize == 0xFFFF_FFFF, field + 8 <= body + length {
                        compressedSize = directory.uint64(at: field)
                        field += 8
                    }
                    if offset == 0xFFFF_FFFF, field + 8 <= body + length {
                        offset = directory.uint64(at: field)
                    }
                }
                extra = body + length
            }

            guard method == 0 || method == 8 else {
                throw CartoucheZipError("\(name) is compressed in a way Cartouche does not read (method \(method))")
            }
            guard flags & 0x0001 == 0 else { throw CartoucheZipError("\(name) is encrypted") }
            guard offset < archiveSize, compressedSize <= archiveSize else {
                throw CartoucheZipError("\(name) lies out of the archive")
            }
            let unix = madeBy >> 8 == 3 && external >> 16 != 0
            entries.append(CartoucheZipEntry(name: name, method: method, crc: crc, compressedSize: compressedSize,
                                             size: size, localHeaderOffset: offset, mode: unix ? external >> 16 : nil))
            at = next
        }
        return entries
    }

    /// The path an entry takes in FOLDER, or nil for one that would leave
    /// it ("..", an absolute path).
    static func safePath(_ name: String) -> String? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: true)
        guard !name.hasPrefix("/"), !name.contains("\\"), !parts.isEmpty,
              !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// One entry's bytes, for a small one such as an Info.plist.
    static func data(of entry: CartoucheZipEntry, in source: CartoucheByteSource, limit: Int = 16 << 20) async throws -> Data {
        guard entry.size <= UInt64(limit), entry.compressedSize <= UInt64(limit) else {
            throw CartoucheZipError("\(entry.name) is too large to read at once")
        }
        let header = try await source.read(at: entry.localHeaderOffset, count: 30)
        guard header.count == 30, header.uint32(at: 0) == localSignature else {
            throw CartoucheZipError("\(entry.name): its local header is damaged")
        }
        let dataAt = entry.localHeaderOffset + 30 + UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28))
        let stored = try await source.read(at: dataAt, count: Int(entry.compressedSize))
        guard stored.count == Int(entry.compressedSize) else { throw CartoucheZipError("the archive ended early") }
        var output = Data()
        var check = CartoucheCRC32()
        if entry.method == 8 {
            let inflater = try CartoucheInflater()
            try inflater.feed(stored, last: true) { chunk in
                check.update(chunk)
                output.append(chunk)
            }
        } else {
            check.update(stored)
            output = stored
        }
        guard UInt64(output.count) == entry.size, check.value == entry.crc else {
            throw CartoucheZipError("\(entry.name) is damaged (its size or CRC-32 does not match)")
        }
        return output
    }

    /// Unpacks the archive into FOLDER, reading it once from start to end.
    /// PROGRESS counts the bytes written; cancelling the task stops it.
    static func extract(_ source: CartoucheByteSource, entries: [CartoucheZipEntry], into folder: URL,
                        progress: Progress? = nil) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let ordered = entries.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        progress?.totalUnitCount = Int64(clamping: ordered.reduce(UInt64(0)) { $0 + $1.size })
        let reader = CartoucheSequentialReader(source)
        var links: [(path: URL, target: String)] = []
        var modes: [(path: URL, mode: UInt32)] = []

        for entry in ordered {
            try Task.checkCancellation()
            guard let relative = safePath(entry.name) else {
                throw CartoucheZipError("\(entry.name) would land outside the folder")
            }
            let path = folder.appendingPathComponent(relative)
            if entry.isDirectory {
                try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
                if let mode = entry.mode { modes.append((path, mode & 0o777 | 0o700)) }
                continue
            }
            try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

            try await reader.seek(to: entry.localHeaderOffset)
            let header = try await reader.read(exactly: 30)
            guard header.uint32(at: 0) == localSignature else {
                throw CartoucheZipError("\(entry.name): its local header is damaged")
            }
            try await reader.skip(UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28)))

            if entry.isSymlink {
                let target = try await reader.read(exactly: Int(min(entry.compressedSize, 4096)))
                guard entry.method == 0, let text = String(data: target, encoding: .utf8),
                      CartoucheCRC32.of(target) == entry.crc else {
                    throw CartoucheZipError("\(entry.name): its link is damaged")
                }
                links.append((path, text))
                // A link's size is its target's, which the total counts.
                progress?.completedUnitCount += Int64(clamping: entry.size)
                continue
            }

            try? fileManager.removeItem(at: path)
            guard fileManager.createFile(atPath: path.path, contents: nil) else {
                throw CartoucheZipError("cannot write \(relative)")
            }
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            var check = CartoucheCRC32()
            var written: UInt64 = 0
            var inflater: CartoucheInflater?
            if entry.method == 8 {
                inflater = try CartoucheInflater()
            }
            var left = entry.compressedSize
            while left > 0 {
                try Task.checkCancellation()
                let chunk = try await reader.read(upTo: Int(min(left, UInt64(CartoucheSequentialReader.chunk))))
                guard !chunk.isEmpty else { throw CartoucheZipError("the archive ended early, in \(entry.name)") }
                left -= UInt64(chunk.count)
                let before = written
                if let inflater {
                    try inflater.feed(chunk, last: left == 0) { output in
                        check.update(output)
                        try handle.write(contentsOf: output)
                        written += UInt64(output.count)
                    }
                } else {
                    check.update(chunk)
                    try handle.write(contentsOf: chunk)
                    written += UInt64(chunk.count)
                }
                progress?.completedUnitCount += Int64(clamping: written - before)
            }
            if let inflater, !inflater.finished {
                throw CartoucheZipError("\(entry.name) is damaged (its deflated data ends early)")
            }
            guard written == entry.size, check.value == entry.crc else {
                throw CartoucheZipError("\(entry.name) is damaged (its size or CRC-32 does not match)")
            }
            if let mode = entry.mode { modes.append((path, mode & 0o777 | 0o600)) }
        }

        // Links last, once their targets are in place; each must stay inside
        // the folder.
        let root = folder.standardizedFileURL.path
        for link in links {
            let resolved = URL(fileURLWithPath: link.target, relativeTo: link.path.deletingLastPathComponent())
                .standardizedFileURL.path
            guard !link.target.hasPrefix("/"), resolved == root || resolved.hasPrefix(root + "/") else {
                throw CartoucheZipError("\(link.path.lastPathComponent) links outside the folder")
            }
            try? fileManager.removeItem(at: link.path)
            try fileManager.createSymbolicLink(atPath: link.path.path, withDestinationPath: link.target)
        }
        for item in modes {
            try? fileManager.setAttributes([.posixPermissions: NSNumber(value: item.mode)], ofItemAtPath: item.path.path)
        }
    }
}

/// Reads a source in order, in large chunks, as the storage serves best.
final class CartoucheSequentialReader {
    static let chunk = 8 << 20

    private let source: CartoucheByteSource
    private var buffer = Data()
    /// Where the buffer starts in the source.
    private var bufferStart: UInt64 = 0
    /// How far into the buffer the reader is.
    private var position = 0

    init(_ source: CartoucheByteSource) {
        self.source = source
    }

    private var offset: UInt64 { bufferStart + UInt64(position) }

    func seek(to target: UInt64) async throws {
        if target >= bufferStart, target <= bufferStart + UInt64(buffer.count) {
            position = Int(target - bufferStart)
            return
        }
        buffer = Data()
        bufferStart = target
        position = 0
    }

    func skip(_ count: UInt64) async throws {
        try await seek(to: offset + count)
    }

    /// Up to COUNT bytes, at least one unless the source has ended.
    func read(upTo count: Int) async throws -> Data {
        if position >= buffer.count {
            let start = offset
            guard start < source.size else { return Data() }
            buffer = try await source.read(at: start, count: Int(min(UInt64(Self.chunk), source.size - start)))
            bufferStart = start
            position = 0
            guard !buffer.isEmpty else { return Data() }
        }
        let taken = min(count, buffer.count - position)
        let from = buffer.startIndex + position
        position += taken
        return buffer.subdata(in: from ..< from + taken)
    }

    func read(exactly count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let part = try await read(upTo: count - data.count)
            guard !part.isEmpty else { throw CartoucheZipError("the archive ended early") }
            data.append(part)
        }
        return data
    }
}

/// Raw DEFLATE (RFC 1951), as zip archives hold it: Compression's ZLIB.
final class CartoucheInflater {
    private let stream: UnsafeMutablePointer<compression_stream>
    private let output: UnsafeMutablePointer<UInt8>
    private static let outputSize = 1 << 20
    private let encoding: Bool
    private(set) var finished = false

    init(encoding: Bool = false) throws {
        self.encoding = encoding
        // Thrown before every property is set, so that deinit does not run.
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        let operation = encoding ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            throw CartoucheZipError("cannot start the deflate stream")
        }
        self.stream = stream
        output = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.outputSize)
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        output.deallocate()
    }

    /// Feeds INPUT and hands each chunk of output to SINK. LAST: no more
    /// input follows; the stream is finished then. A decoder must be told
    /// too: it may keep the last bytes it read, and what they decode to,
    /// until more input comes, so that a stream fed in pieces never
    /// reached its end (a game's RomFS image, read 8 MiB at a time).
    func feed(_ input: Data, last: Bool, sink: (Data) throws -> Void) throws {
        let finalizing = last
        let flags = finalizing ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            // An empty input still needs a valid pointer.
            var placeholder: UInt8 = 0
            try withUnsafeMutablePointer(to: &placeholder) { empty in
                stream.pointee.src_ptr = UnsafePointer(bytes.baseAddress ?? UnsafePointer(empty))
                stream.pointee.src_size = bytes.count
                while true {
                    if finished { return }
                    stream.pointee.dst_ptr = output
                    stream.pointee.dst_size = Self.outputSize
                    let status = compression_stream_process(stream, flags)
                    let produced = Self.outputSize - stream.pointee.dst_size
                    if produced > 0 {
                        try sink(Data(bytes: output, count: produced))
                    }
                    switch status {
                    case COMPRESSION_STATUS_END:
                        finished = true
                        return
                    case COMPRESSION_STATUS_OK:
                        // All input taken and room left over: it wants more,
                        // unless it is finishing its stream.
                        if stream.pointee.src_size == 0, produced < Self.outputSize {
                            guard finalizing else { return }
                            // A decoder at the end of what it was given
                            // without the end of its stream: the caller
                            // finds it unfinished.
                            if produced == 0 {
                                if encoding { throw CartoucheZipError("the deflate stream did not end") }
                                return
                            }
                        }
                    default:
                        throw CartoucheZipError("the deflated data is damaged")
                    }
                }
            }
        }
    }
}

/// CRC-32 (ISO 3309), as zip archives check their entries with.
struct CartoucheCRC32 {
    private(set) var value: UInt32 = 0

    private static let table: [UInt32] = (0 ..< 256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0 ..< 8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    private typealias Zlib = @convention(c) (UInt, UnsafePointer<UInt8>?, UInt32) -> UInt
    /// zlib's crc32, faster, when the process has it loaded (iOS does).
    private static let zlib: Zlib? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "crc32") else { return nil }
        return unsafeBitCast(symbol, to: Zlib.self)
    }()

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            update(raw)
        }
    }

    mutating func update(_ raw: UnsafeRawBufferPointer) {
        let bytes = raw.bindMemory(to: UInt8.self)
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        if let zlib = Self.zlib {
            var crc = UInt(value)
            var at = 0
            while at < bytes.count {
                let count = min(bytes.count - at, 1 << 30)
                crc = zlib(crc, base + at, UInt32(count))
                at += count
            }
            value = UInt32(truncatingIfNeeded: crc)
            return
        }
        var c = ~value
        Self.table.withUnsafeBufferPointer { table in
            for byte in bytes {
                c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        value = ~c
    }

    static func of(_ data: Data) -> UInt32 {
        var check = CartoucheCRC32()
        check.update(data)
        return check.value
    }
}

/// Writes a zip archive in order to SINK.
final class CartoucheZipWriter {
    /// Files up to this size are tried deflated.
    static let deflateLimit = 4 << 20

    private let sink: CartoucheByteSink
    private var offset: UInt64 = 0
    private var central = Data()
    private var count: UInt64 = 0
    private var pending = Data()
    /// Writes Zip64 fields even when the numbers fit: for the tests.
    var alwaysZip64 = false

    init(sink: CartoucheByteSink) {
        self.sink = sink
    }

    /// The bytes written so far.
    var written: UInt64 { offset }

    func addFolder(_ name: String, mode: UInt32 = 0o755, date: Date = Date()) async throws {
        let folderName = name.hasSuffix("/") ? name : name + "/"
        try await add(folderName, method: 0, crc: 0, compressedSize: 0, size: 0, mode: 0o040000 | (mode & 0o7777), date: date)
    }

    func addData(_ name: String, _ data: Data, mode: UInt32 = 0o644, date: Date = Date()) async throws {
        let crc = CartoucheCRC32.of(data)
        var deflated: Data?
        if data.count >= 64 {
            deflated = try Self.deflate(data)
        }
        if let deflated, deflated.count < data.count {
            try await add(name, method: 8, crc: crc, compressedSize: UInt64(deflated.count), size: UInt64(data.count),
                          mode: 0o100000 | (mode & 0o7777), date: date)
            try await emit(deflated)
        } else {
            try await add(name, method: 0, crc: crc, compressedSize: UInt64(data.count), size: UInt64(data.count),
                          mode: 0o100000 | (mode & 0o7777), date: date)
            try await emit(data)
        }
    }

    func addSymlink(_ name: String, target: String, date: Date = Date()) async throws {
        let data = Data(target.utf8)
        try await add(name, method: 0, crc: CartoucheCRC32.of(data), compressedSize: UInt64(data.count),
                      size: UInt64(data.count), mode: 0o120777, date: date)
        try await emit(data)
    }

    /// A file of the iPhone: read once for its CRC-32, then again into the
    /// archive. AFTER is told the bytes added, as they go.
    func addFile(_ name: String, from url: URL, mode: UInt32 = 0o644, date: Date = Date(),
                 after: ((UInt64) -> Void)? = nil) async throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = UInt64(values.fileSize ?? 0)
        if size <= UInt64(Self.deflateLimit) {
            let data = try Data(contentsOf: url)
            try await addData(name, data, mode: mode, date: date)
            after?(UInt64(data.count))
            return
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var check = CartoucheCRC32()
        var counted: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.cartoucheRead(upToCount: CartoucheSequentialReader.chunk) else { break }
            check.update(chunk)
            counted += UInt64(chunk.count)
        }
        guard counted == size else { throw CartoucheZipError("\(name) changed while Cartouche read it") }
        try handle.seek(toOffset: 0)
        try await add(name, method: 0, crc: check.value, compressedSize: size, size: size,
                      mode: 0o100000 | (mode & 0o7777), date: date)
        var sent: UInt64 = 0
        var again = CartoucheCRC32()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.cartoucheRead(upToCount: CartoucheSequentialReader.chunk) else { break }
            again.update(chunk)
            try await emit(chunk)
            sent += UInt64(chunk.count)
            after?(UInt64(chunk.count))
        }
        guard sent == size, again.value == check.value else {
            throw CartoucheZipError("\(name) changed while Cartouche read it")
        }
    }

    /// The central directory and the end records.
    func finish() async throws {
        let directoryOffset = offset
        let directory = central
        try await emit(directory)
        let directorySize = UInt64(directory.count)
        var end = Data()
        if alwaysZip64 || count >= 0xFFFF || directoryOffset >= 0xFFFF_FFFF || directorySize >= 0xFFFF_FFFF {
            let end64Offset = offset
            end.appendUInt32(CartoucheZip.end64Signature)
            end.appendUInt64(44)
            end.appendUInt16(0x031E)
            end.appendUInt16(45)
            end.appendUInt32(0)
            end.appendUInt32(0)
            end.appendUInt64(count)
            end.appendUInt64(count)
            end.appendUInt64(directorySize)
            end.appendUInt64(directoryOffset)
            end.appendUInt32(CartoucheZip.locator64Signature)
            end.appendUInt32(0)
            end.appendUInt64(end64Offset)
            end.appendUInt32(1)
        }
        // With alwaysZip64, the fields say to read the Zip64 record.
        let countField = alwaysZip64 ? 0xFFFF : UInt16(min(count, 0xFFFF))
        end.appendUInt32(CartoucheZip.endSignature)
        end.appendUInt16(0)
        end.appendUInt16(0)
        end.appendUInt16(countField)
        end.appendUInt16(countField)
        end.appendUInt32(alwaysZip64 ? 0xFFFF_FFFF : UInt32(min(directorySize, 0xFFFF_FFFF)))
        end.appendUInt32(alwaysZip64 ? 0xFFFF_FFFF : UInt32(min(directoryOffset, 0xFFFF_FFFF)))
        end.appendUInt16(0)
        try await emit(end)
        try await flush()
    }

    // MARK: Parts

    private func add(_ name: String, method: UInt16, crc: UInt32, compressedSize: UInt64, size: UInt64,
                     mode: UInt32, date: Date) async throws {
        let nameBytes = Data(name.utf8)
        guard nameBytes.count <= 0xFFFF else { throw CartoucheZipError("the name \(name) is too long") }
        let flags: UInt16 = name.utf8.contains(where: { $0 >= 0x80 }) ? 0x0800 : 0
        let (time, day) = Self.dosTime(date)
        let headerOffset = offset
        let zip64Sizes = alwaysZip64 || size >= 0xFFFF_FFFF || compressedSize >= 0xFFFF_FFFF
        let needed: UInt16 = zip64Sizes || headerOffset >= 0xFFFF_FFFF ? 45 : method == 8 ? 20 : 10

        var local = Data()
        local.appendUInt32(CartoucheZip.localSignature)
        local.appendUInt16(needed)
        local.appendUInt16(flags)
        local.appendUInt16(method)
        local.appendUInt16(time)
        local.appendUInt16(day)
        local.appendUInt32(crc)
        local.appendUInt32(zip64Sizes ? 0xFFFF_FFFF : UInt32(compressedSize))
        local.appendUInt32(zip64Sizes ? 0xFFFF_FFFF : UInt32(size))
        local.appendUInt16(UInt16(nameBytes.count))
        local.appendUInt16(zip64Sizes ? 20 : 0)
        local.append(nameBytes)
        if zip64Sizes {
            // A local Zip64 field holds both sizes.
            local.appendUInt16(0x0001)
            local.appendUInt16(16)
            local.appendUInt64(size)
            local.appendUInt64(compressedSize)
        }

        var fields: [UInt64] = []
        if alwaysZip64 || size >= 0xFFFF_FFFF { fields.append(size) }
        if alwaysZip64 || compressedSize >= 0xFFFF_FFFF { fields.append(compressedSize) }
        if alwaysZip64 || headerOffset >= 0xFFFF_FFFF { fields.append(headerOffset) }
        var entry = Data()
        entry.appendUInt32(CartoucheZip.centralSignature)
        entry.appendUInt16(0x031E)
        entry.appendUInt16(needed)
        entry.appendUInt16(flags)
        entry.appendUInt16(method)
        entry.appendUInt16(time)
        entry.appendUInt16(day)
        entry.appendUInt32(crc)
        entry.appendUInt32(alwaysZip64 || compressedSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(compressedSize))
        entry.appendUInt32(alwaysZip64 || size >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(size))
        entry.appendUInt16(UInt16(nameBytes.count))
        entry.appendUInt16(fields.isEmpty ? 0 : UInt16(4 + 8 * fields.count))
        entry.appendUInt16(0)
        entry.appendUInt16(0)
        entry.appendUInt16(0)
        entry.appendUInt32((mode << 16) | (mode & 0o170000 == 0o040000 ? 0x10 : 0))
        entry.appendUInt32(alwaysZip64 || headerOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(headerOffset))
        entry.append(nameBytes)
        if !fields.isEmpty {
            entry.appendUInt16(0x0001)
            entry.appendUInt16(UInt16(8 * fields.count))
            for field in fields { entry.appendUInt64(field) }
        }
        central.append(entry)
        count += 1
        try await emit(local)
    }

    /// Buffers small writes into chunks of a few megabytes.
    private func emit(_ data: Data) async throws {
        offset += UInt64(data.count)
        pending.append(data)
        if pending.count >= CartoucheSequentialReader.chunk {
            try await flush()
        }
    }

    private func flush() async throws {
        guard !pending.isEmpty else { return }
        let data = pending
        pending = Data()
        try await sink.write(data)
    }

    static func deflate(_ data: Data) throws -> Data {
        let deflater = try CartoucheInflater(encoding: true)
        var output = Data()
        try deflater.feed(data, last: true) { output.append($0) }
        return output
    }

    /// MS-DOS time and date, in local time, as zip archives keep them.
    static func dosTime(_ date: Date) -> (UInt16, UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(0, min(127, (parts.year ?? 1980) - 1980))
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }
}

// MARK: Little-endian fields

fileprivate extension Data {
    func uint16(at index: Int) -> UInt16 {
        let i = startIndex + index
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func uint32(at index: Int) -> UInt32 {
        let i = startIndex + index
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func uint64(at index: Int) -> UInt64 {
        UInt64(uint32(at: index)) | UInt64(uint32(at: index + 4)) << 32
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendUInt16(UInt16(value & 0xFFFF))
        appendUInt16(UInt16(value >> 16))
    }

    mutating func appendUInt64(_ value: UInt64) {
        appendUInt32(UInt32(value & 0xFFFF_FFFF))
        appendUInt32(UInt32(value >> 32))
    }
}

// MARK: Files of the iPhone

/// A file of the iPhone, read at any offset.
final class CartoucheFileSource: CartoucheByteSource {
    let size: UInt64
    private let handle: FileHandle

    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.cartoucheRead(upToCount: count) ?? Data()
    }
}

extension FileHandle {
    /// Up to COUNT bytes, or nil at the end, read in an autorelease pool of
    /// its own. FileHandle hands its data over autoreleased, so a loop that
    /// reads a large file without returning to the run loop keeps every
    /// chunk it read until it ends: copying Mario Kart World to a NAS, the
    /// CRC-32 pass over its 21 GiB romfs.img filled the memory iOS allows
    /// Cartouche, which iOS then closed.
    func cartoucheRead(upToCount count: Int) throws -> Data? {
        try autoreleasepool {
            guard let data = try read(upToCount: count), !data.isEmpty else { return nil }
            return data
        }
    }
}

/// A file of the iPhone, written from start to end.
final class CartoucheFileSink: CartoucheByteSink {
    private let handle: FileHandle

    init(_ url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
    }

    func write(_ data: Data) async throws {
        try handle.write(contentsOf: data)
    }

    func close() throws {
        try handle.close()
    }
}
