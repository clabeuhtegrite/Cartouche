import XCTest
@testable import CartoucheCore

/// Raw DEFLATE fed as a game's archive feeds it: in pieces, the last of any
/// size, and past 4 GiB for a large game's RomFS image.
final class CartoucheInflaterTests: XCTestCase {
    /// Bytes that deflate only a little, as a game's data does.
    private func sample(_ count: Int) -> Data {
        var data = Data(count: count)
        var state: UInt32 = 0x1234_5678
        for index in 0 ..< count {
            state = state &* 1_664_525 &+ 1_013_904_223
            data[index] = index % 7 == 0 ? 0 : UInt8(truncatingIfNeeded: state >> 24)
        }
        return data
    }

    private func deflate(_ data: Data) throws -> Data {
        let encoder = try CartoucheInflater(encoding: true)
        var out = Data()
        try encoder.feed(data, last: true) { out.append($0) }
        return out
    }

    /// Decodes COMPRESSED fed in pieces of SIZES (the last one repeated);
    /// whether the stream ended, and what came out.
    private func inflate(_ compressed: Data, pieces sizes: [Int]) throws -> (finished: Bool, output: Data) {
        let decoder = try CartoucheInflater()
        var output = Data()
        var at = compressed.startIndex
        var index = 0
        while at < compressed.endIndex {
            let size = sizes[min(index, sizes.count - 1)]
            let end = min(at + size, compressed.endIndex)
            try decoder.feed(compressed.subdata(in: at ..< end), last: end == compressed.endIndex) { output.append($0) }
            at = end
            index += 1
        }
        return (decoder.finished, output)
    }

    func testWholeStream() throws {
        let data = sample(3 << 20)
        let compressed = try deflate(data)
        let result = try inflate(compressed, pieces: [compressed.count])
        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.output, data)
    }

    func testLastPieceOfEverySmallSize() throws {
        let data = sample(2 << 20)
        let compressed = try deflate(data)
        for tail in 1 ... 12 {
            let result = try inflate(compressed, pieces: [compressed.count - tail, tail])
            XCTAssertTrue(result.finished, "last piece of \(tail) bytes")
            XCTAssertEqual(result.output, data, "last piece of \(tail) bytes")
        }
    }

    func testSmallPieces() throws {
        let data = sample(1 << 20)
        let compressed = try deflate(data)
        for size in [1, 7, 4096, 65_537, 100_000, 333_333] {
            let result = try inflate(compressed, pieces: [size])
            XCTAssertTrue(result.finished, "pieces of \(size) bytes")
            XCTAssertEqual(result.output, data, "pieces of \(size) bytes")
        }
    }

    /// Stored blocks, as zlib writes for data that does not deflate, for
    /// more than 4 GiB, fed in the archive reader's 8 MiB pieces.
    func testStoredBlocksPast4GiB() throws {
        let payload = 65_535
        let blocks = 128
        var piece = Data()
        let body = sample(payload)
        for _ in 0 ..< blocks {
            piece.append(0x00)
            piece.append(contentsOf: [UInt8(payload & 0xFF), UInt8(payload >> 8), UInt8(~payload & 0xFF), UInt8((~payload >> 8) & 0xFF)])
            piece.append(body)
        }
        var last = Data([0x01, 10, 0, 0xF5, 0xFF])
        last.append(Data(repeating: 0x42, count: 10))
        let pieces = Int((UInt64(1) << 32) / UInt64(payload * blocks)) + 4

        let decoder = try CartoucheInflater()
        var produced: UInt64 = 0
        for _ in 0 ..< pieces {
            try decoder.feed(piece, last: false) { produced += UInt64($0.count) }
            XCTAssertFalse(decoder.finished)
        }
        try decoder.feed(last, last: true) { produced += UInt64($0.count) }
        XCTAssertTrue(decoder.finished, "the stream ended after \(produced) bytes")
        XCTAssertEqual(produced, UInt64(pieces) * UInt64(payload * blocks) + 10)
    }
}
