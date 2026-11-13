//
//  CartoucheGameSigning.swift
//  Cartouche
//
//  Signing a game for this iPhone, as LiveContainer does with zsign, and
//  why a game did not sign or did not start, in names only.
//
//  The files zsign signs. LiveContainer handed it every 64-bit Mach-O of the
//  game's bundle (zsign's is_64bit_macho), whatever its processor: a GPU's
//  too. nxnative bundles the Metal pipeline archive it made offline for a
//  game built with pso_mtl4 on, pso/applegpu_<GPU>.mtl4a, which is a
//  Mach-O of Apple's GPU: zsign cannot sign it, as it has no room for a
//  signature, and failed the whole signing. Every install of The Legend of
//  Zelda: Breath of the Wild, the only such game, ended "Installed, but not
//  signed", its executable signed all the same. LiveContainer now hands
//  zsign the files iOS loads code from only (filesToSign, which
//  app/patches/livecontainer/0013 calls): an executable, a library or a
//  bundle of the iPhone's processor, alone or as a slice of a universal
//  file. Nothing else needs a signature for a game to start.
//
//  Why signing failed. LiveContainer and zsign say it in their own words,
//  in English, with the path of each file: Cartouche tells the player in
//  theirs, keeps the words for the report, and sends only the reason it
//  tells from them, with the kind of file and how many (Failure.details).
//
//  Why the game's process ended on an error. Behind the console,
//  LiveContainer's LiveProcess says why as it ends the game's process: it
//  could not run the game, in dyld's words or its own, or the game ended
//  itself, or threw. The same, as StartFailure.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

enum CartoucheGameSigning {
    // MARK: The files zsign signs

    /// CPU_TYPE_ARM64: the iPhone's processor, arm64 and arm64e alike.
    static let arm64: UInt32 = 0x0100_000C
    /// The Mach-O files iOS loads code from: an executable (MH_EXECUTE), a
    /// library (MH_DYLIB) and a bundle (MH_BUNDLE).
    static let loadedFileTypes: Set<UInt32> = [0x2, 0x6, 0x8]

    /// The files of the app at BUNDLE that zsign signs: among its regular
    /// files, the hidden ones left out, as zsign went through them, those
    /// iOS loads code from (isSignable).
    static func filesToSign(inBundle bundle: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true, isSignable(at: url) else { continue }
            files.append(url)
        }
        return files
    }

    /// Whether the file at URL is one iOS loads code from, which zsign
    /// signs: a 64-bit Mach-O of the iPhone's processor, of a type iOS
    /// loads, or a universal file with such a slice, in the form zsign reads
    /// (offsets of 32 bits). Never a Mach-O of another processor's, such as
    /// a Metal pipeline archive, the GPU's.
    static func isSignable(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        return isSignable(size: size) { offset, count in
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: count)
        }
    }

    /// The same, for a file of SIZE bytes, of which READ gives COUNT bytes
    /// from OFFSET.
    static func isSignable(size: UInt64, read: (_ offset: UInt64, _ count: Int) -> Data?) -> Bool {
        guard size >= 32, let head = read(0, 8), head.count == 8 else { return false }
        switch little(head, 0) {
        case 0xFEED_FACF:
            // MH_MAGIC_64: a Mach-O of one processor.
            return isLoadedARM64(at: 0, end: size, read: read)
        case 0xBEBA_FECA:
            // FAT_MAGIC, its bytes big-endian, as zsign takes it: a
            // universal file, its slices listed after its header. A Java
            // class starts the same way, with a version where the number
            // of slices is: 45 and more.
            let count = Int(big(head, 4))
            guard (1...32).contains(count), 8 + UInt64(count) * 20 <= size,
                  let table = read(8, count * 20), table.count == count * 20 else { return false }
            for index in 0..<count where big(table, index * 20) == arm64 {
                let offset = UInt64(big(table, index * 20 + 8)), length = UInt64(big(table, index * 20 + 12))
                if offset + length <= size, isLoadedARM64(at: offset, end: offset + length, read: read) {
                    return true
                }
            }
            return false
        default:
            return false
        }
    }

    /// Whether a 64-bit Mach-O of the iPhone's processor, of a type iOS
    /// loads, starts at OFFSET, and its header ends before END.
    private static func isLoadedARM64(at offset: UInt64, end: UInt64, read: (UInt64, Int) -> Data?) -> Bool {
        guard offset + 32 <= end, let header = read(offset, 16), header.count == 16 else { return false }
        return little(header, 0) == 0xFEED_FACF && little(header, 4) == arm64 && loadedFileTypes.contains(little(header, 12))
    }

    private static func little(_ data: Data, _ at: Int) -> UInt32 {
        let start = data.startIndex + at
        return data[start..<start + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func big(_ data: Data, _ at: Int) -> UInt32 {
        let start = data.startIndex + at
        return data[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    // MARK: Why signing failed

    /// Why LiveContainer did not sign a game: a key that stays the same in
    /// every language and every version. Those of LiveContainer's own keys
    /// are the kinds the measurements gave them before.
    enum Reason: String, CaseIterable, Sendable {
        /// No certificate: Cartouche's setup has not handed LiveContainer
        /// the built-in SideStore's yet (lc.signer.noCertificateFoundErr).
        case noCertificate = "noCertificateFound"
        /// Signed, but iOS refuses the certificate: revoked, or expired
        /// (lc.signer.latestCertificateInvalidErr).
        case certificateRefused = "latestCertificateInvalid"
        /// zsign could not open the certificate with its password.
        case certificateUnreadable
        /// zsign could not be loaded.
        case signerMissing
        /// zsign could not sign one file or more.
        case filesNotSigned
        /// zsign was handed a file that is no Mach-O it reads.
        case notMachO
        /// The app is encrypted, as the App Store delivers it: no copy of
        /// LiveContainer can run it.
        case encrypted
        /// LiveContainer could not read the game's executable.
        case executableUnreadable
        /// The app has no Info.plist.
        case infoPlistMissing
        /// The app stopped while it signed (lc.signer.crashDuringSignErr).
        case interrupted = "crashDuringSign"
        case other

        /// The cause an error of this reason counts under.
        var cause: CartoucheFailure.Cause {
            switch self {
            case .noCertificate, .certificateRefused, .certificateUnreadable: return .certificate
            default: return .notSigned
            }
        }

        /// Whether signing the game again, now, may get further: not for an
        /// app no copy of LiveContainer runs, nor for files to install
        /// again, nor before Cartouche has a certificate that works.
        var signingAgainHelps: Bool {
            switch self {
            case .encrypted, .executableUnreadable, .infoPlistMissing, .noCertificate, .certificateUnreadable,
                 .certificateRefused: return false
            default: return true
            }
        }
    }

    /// Why a game did not sign, in names and numbers.
    struct Failure: Equatable, Sendable {
        var reason: Reason
        /// The kind of the file zsign could not sign, the most needed first:
        /// "executable", the game's own; "framework", "library", "plugIn",
        /// or "other".
        var fileKind: String?
        /// How many files zsign could not sign.
        var files: Int?
        /// LiveContainer said the game was signed all the same
        /// (lc.appList.signSuccessWithError).
        var signedAnyway = false

        /// What goes with the error, for the measurements and the report:
        /// names and numbers, never a path.
        var details: [String: CartoucheTelemetryValue] {
            var details: [String: CartoucheTelemetryValue] = ["kind": .text(reason.rawValue)]
            if let fileKind { details["fileKind"] = .text(fileKind) }
            if let files { details["files"] = .number(Double(files)) }
            if signedAnyway { details["signedAnyway"] = .flag(true) }
            return details
        }
    }

    /// LiveContainer's keys for its own errors, and the reason of each.
    static let keys: [(key: String, reason: Reason)] = [
        ("lc.signer.noCertificateFoundErr", .noCertificate),
        ("lc.signer.latestCertificateInvalidErr", .certificateRefused),
        ("lc.signer.crashDuringSignErr", .interrupted),
    ]

    /// Why LiveContainer did not sign a game, from its MESSAGE: one of its
    /// keys, or its or zsign's words, as LCAppInfo's
    /// patchExecAndSignIfNeed passes them on, or as LOCALIZED gives a key in
    /// the player's language. SIGNED: LiveContainer said the game was signed
    /// all the same. EXECUTABLE: the name of the game's executable
    /// (CFBundleExecutable), to tell it among the files.
    static func failure(_ message: String, signed: Bool = false, executable: String? = nil,
                        localized: (String) -> String = { $0 }) -> Failure {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = keys.first(where: { text == $0.key || text == localized($0.key) }) {
            return Failure(reason: known.reason, signedAnyway: signed)
        }
        // zsign's own: a line for each file it could not sign or read.
        var unsigned: [String] = []
        var unread: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("Failed to Sign ") {
                unsigned.append(String(line.dropFirst("Failed to Sign ".count)))
            } else if line.hasPrefix("Invalid mach-o file! ") {
                unread.append(String(line.dropFirst("Invalid mach-o file! ".count)))
            }
        }
        if !unsigned.isEmpty || !unread.isEmpty {
            let paths = unsigned + unread
            let kinds = paths.map { fileKind(of: $0, executable: executable) }
            return Failure(reason: unsigned.isEmpty ? .notMachO : .filesNotSigned,
                           fileKind: fileKinds.first(where: kinds.contains), files: paths.count, signedAnyway: signed)
        }
        let reason: Reason
        if text.hasPrefix("Failed to load ZSign") {
            reason = .signerMissing
        } else if text.contains("zSignAsset") {
            reason = .certificateUnreadable
        } else if text.hasPrefix("The app you tried to install is encrypted") {
            reason = .encrypted
        } else if text == "Info.plist not found" {
            reason = .infoPlistMissing
        } else if text.hasPrefix("Failed to map ") || text.hasPrefix("Failed to open ") || text == "Not a Mach-O file" {
            // LCParseMachO's, on the game's executable.
            reason = .executableUnreadable
        } else {
            reason = .other
        }
        return Failure(reason: reason, signedAnyway: signed)
    }

    /// The kinds of file, the most needed for the game to start first.
    static let fileKinds = ["executable", "framework", "library", "plugIn", "other"]

    /// What the file at PATH, in a game's bundle, is to the game.
    static func fileKind(of path: String, executable: String?) -> String {
        var parts = path.split(separator: "/").map(String.init)
        // Its path in the bundle, whose folder is the first named .app.
        if let bundle = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            parts.removeSubrange(...bundle)
            if let executable, parts == [executable] { return "executable" }
        }
        if parts.contains(where: { $0 == "PlugIns" || $0 == "Extensions" || $0.hasSuffix(".appex") }) { return "plugIn" }
        if parts.contains(where: { $0.hasSuffix(".framework") }) { return "framework" }
        if path.hasSuffix(".dylib") { return "library" }
        return "other"
    }

    // MARK: Why the game's process ended on an error

    /// Why LiveContainer's LiveProcess ended the game's process, from what
    /// it said as it did: dyld's words as it could not load the game, its
    /// own, or the game's, which ended itself or threw, as it started or
    /// later.
    struct StartFailure: Equatable, Sendable {
        enum Kind: String, CaseIterable, Sendable {
            /// iOS refused the signature of the game or of one of its
            /// libraries.
            case codeSignature
            /// A library the game needs is not there.
            case libraryMissing
            /// A function the game needs is in none of its libraries.
            case symbolMissing
            /// Code for another processor or another system.
            case architecture
            /// The game's executable or bundle is not there.
            case fileMissing
            /// The executable has no entry point.
            case noEntryPoint
            /// The game's main function returned, the game ending itself.
            case returnedFromMain
            /// The game threw an exception it did not catch.
            case exception
            /// The game's process crashed before it could say anything.
            case crashedAtStart
            /// LiveContainer asked for JIT.
            case jitRequired
            /// The game's data folder is not there.
            case containerMissing
            case other
        }

        var kind: Kind
        /// For returnedFromMain, what the main function returned.
        var code: Int?

        /// The cause an error of this kind counts under.
        var cause: CartoucheFailure.Cause {
            kind == .codeSignature ? .notSigned : .gameEndedOnError
        }

        /// Whether signing the game again may let it start.
        var signingAgainHelps: Bool { kind == .codeSignature }

        var details: [String: CartoucheTelemetryValue] {
            var details: [String: CartoucheTelemetryValue] = ["kind": .text(kind.rawValue)]
            if let code { details["code"] = .number(Double(code)) }
            return details
        }
    }

    /// Why the game's process ended, from LiveProcess's MESSAGE.
    static func startFailure(_ message: String) -> StartFailure {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        // A library dyld could not load for its signature says both:
        // the signature goes first.
        if ["code signature", "code signing", "not valid for use in process", "trust evaluation failed"]
            .contains(where: lowered.contains) {
            return StartFailure(kind: .codeSignature)
        }
        if text.hasPrefix("App returned from its main function with code ") {
            let number = text.dropFirst("App returned from its main function with code ".count).prefix { $0 == "-" || $0.isNumber }
            return StartFailure(kind: .returnedFromMain, code: Int(number))
        }
        let kind: StartFailure.Kind
        if text.contains("\nCall stack:") {
            kind = .exception
        } else if lowered.contains("library not loaded") {
            kind = .libraryMissing
        } else if lowered.contains("symbol not found") {
            kind = .symbolMissing
        } else if lowered.contains("incompatible architecture") || lowered.contains("wrong architecture")
                    || lowered.contains("incompatible platform") {
            kind = .architecture
        } else if lowered.contains("no such file") || text.hasPrefix("App's executable path not found")
                    || text.hasPrefix("App bundle not found") || text == "App not found" {
            kind = .fileMissing
        } else if text == "Could not find the main entry point" {
            kind = .noEntryPoint
        } else if text.hasPrefix("Failed to start app. Child process has unexpectedly crashed") {
            kind = .crashedAtStart
        } else if text.contains("JIT") {
            kind = .jitRequired
        } else if text.hasPrefix("Container not found") {
            kind = .containerMissing
        } else {
            kind = .other
        }
        return StartFailure(kind: kind)
    }
}

#if canImport(ObjectiveC)
/// LiveContainer's signing asks Cartouche which files of a game zsign signs
/// (app/patches/livecontainer/0013): CartoucheGameSigning.filesToSign.
@objc(CartoucheSignedFiles)
public final class CartoucheSignedFiles: NSObject {
    @objc public static func paths(inBundle bundle: String) -> [String] {
        CartoucheGameSigning.filesToSign(inBundle: URL(fileURLWithPath: bundle, isDirectory: true)).map(\.path)
    }
}
#endif
