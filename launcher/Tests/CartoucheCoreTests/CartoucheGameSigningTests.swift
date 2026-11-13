import XCTest
@testable import CartoucheCore

final class CartoucheGameSigningTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheGameSigningTests-" + UUID().uuidString,
                                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Files

    private static let arm64: UInt32 = 0x0100_000C
    private static let x86_64: UInt32 = 0x0100_0007
    private static let arm: UInt32 = 12
    /// Apple's GPU, as a Metal binary archive's Mach-O names it.
    private static let gpu: UInt32 = 0x0100_0013

    /// A 64-bit Mach-O, little-endian, as Xcode or Metal writes one.
    private static func machO(cpu: UInt32, fileType: UInt32, subtype: UInt32 = 0, bytes: Int = 4096) -> Data {
        var data = Data()
        for value in [0xFEED_FACF, cpu, subtype, fileType, 0, 0, 0x0020_0085, 0] as [UInt32] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(Data(repeating: 0xA5, count: max(0, bytes - data.count)))
        return data
    }

    /// A universal file of SLICES, its header big-endian, each slice at a
    /// multiple of 4 KiB.
    private static func universal(_ slices: [(cpu: UInt32, data: Data)], magic: UInt32 = 0xCAFE_BABE) -> Data {
        var header = Data()
        func big(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { header.append(contentsOf: $0) } }
        big(magic)
        big(UInt32(slices.count))
        var offset = 4096
        var body = Data()
        for slice in slices {
            big(slice.cpu); big(0); big(UInt32(offset)); big(UInt32(slice.data.count)); big(12)
            body.append(slice.data)
            body.append(Data(count: (4096 - slice.data.count % 4096) % 4096))
            offset += slice.data.count + (4096 - slice.data.count % 4096) % 4096
        }
        header.append(Data(count: 4096 - header.count))
        return header + body
    }

    @discardableResult
    private func write(_ data: Data, _ path: String) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private static func plist(_ keys: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: keys, format: .xml, options: 0)
    }

    /// A game's bundle as nxnative builds it (build_ipa.sh): its
    /// executable, Info.plist and PkgInfo, dm/ with its settings screen,
    /// romfs.img, MoltenVK, and the Metal pipeline archive of a game built
    /// with pso_mtl4, as Breath of the Wild is; with the code a bundle may
    /// hold besides, a library and a plug-in, thin or universal, and every
    /// kind of file iOS loads no code from.
    private func makeBundle() throws -> URL {
        try write(Self.machO(cpu: Self.arm64, fileType: 2), "Game.app/Game")
        try write(Self.plist(["CFBundleExecutable": "Game", "CFBundleIdentifier": "org.nxnative.01007ef00011e000",
                              "CFBundlePackageType": "APPL", "DMTitleID": "01007EF00011E000"]), "Game.app/Info.plist")
        try write(Data("APPL????".utf8), "Game.app/PkgInfo")
        try write(Data("{\"settings\":[]}".utf8), "Game.app/dm/launcher.json")
        try write(Data("DM_LANG\tchoice\tLanguage\n".utf8), "Game.app/dm/settings.tsv")
        try write(Self.plist(["files": [String: Any]()]), "Game.app/_CodeSignature/CodeResources")
        try write(Self.machO(cpu: Self.arm64, fileType: 6), "Game.app/Frameworks/MoltenVK.framework/MoltenVK")
        try write(Self.plist(["CFBundleExecutable": "MoltenVK", "CFBundlePackageType": "FMWK"]),
                  "Game.app/Frameworks/MoltenVK.framework/Info.plist")
        try write(Self.universal([(Self.arm, Self.machO(cpu: Self.arm, fileType: 8)),
                                  (Self.arm64, Self.machO(cpu: Self.arm64, fileType: 8))]), "Game.app/PlugIns/Widget.appex/Widget")
        // arm64e, the same processor.
        try write(Self.machO(cpu: Self.arm64, fileType: 6, subtype: 2), "Game.app/Frameworks/libextra.dylib")
        // The Metal pipeline archive nxnative bundles, a universal file of
        // the GPU's, and one of a single GPU.
        try write(Self.universal([(Self.gpu, Self.machO(cpu: Self.gpu, fileType: 2, bytes: 8192))]),
                  "Game.app/pso/applegpu_g18p.mtl4a")
        try write(Self.machO(cpu: Self.gpu, fileType: 2), "Game.app/pso/applegpu_g17p.mtl4a")
        try write(Data("chain\tfixture\n".utf8), "Game.app/pso/prebuilt.tsv")
        try write(Data("MTLB".utf8) + Data(repeating: 1, count: 4092), "Game.app/msl/game.metallib")
        try write(Data("DMROMFS1".utf8) + Data(repeating: 2, count: 4088), "Game.app/romfs.img")
        // Code iOS never loads: another processor's, an object file, 32
        // bits, a universal file zsign cannot read (64-bit offsets).
        try write(Self.machO(cpu: Self.x86_64, fileType: 2), "Game.app/tools/helper")
        try write(Self.machO(cpu: Self.arm64, fileType: 1), "Game.app/tools/part.o")
        var thin32 = Data()
        for value in [0xFEED_FACE, Self.arm, 0, 2, 0, 0, 0] as [UInt32] {
            withUnsafeBytes(of: value.littleEndian) { thin32.append(contentsOf: $0) }
        }
        try write(thin32 + Data(count: 4068), "Game.app/tools/legacy")
        try write(Self.universal([(Self.arm64, Self.machO(cpu: Self.arm64, fileType: 6))], magic: 0xCAFE_BABF),
                  "Game.app/tools/fat64.dylib")
        // A Java class starts as a universal file does.
        try write(Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34]) + Data(repeating: 7, count: 2040), "Game.app/Lib/Main.class")
        // Hidden, or a link: zsign never went through them.
        try write(Self.machO(cpu: Self.arm64, fileType: 6), "Game.app/.hidden.dylib")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("Game.app/GameLink").path,
                                                   withDestinationPath: "Game")
        return folder.appendingPathComponent("Game.app", isDirectory: true)
    }

    /// The files of makeBundle iOS loads code from, in each place a game's
    /// bundle holds code: its executable, a framework, a library and a
    /// plug-in, thin or universal. zsign must get every one of them.
    private static let codeFiles = ["Game", "Frameworks/MoltenVK.framework/MoltenVK", "Frameworks/libextra.dylib",
                                    "PlugIns/Widget.appex/Widget"]

    /// The files zsign gets, by their path in the bundle.
    private func signedFiles(in bundle: URL) -> [String] {
        CartoucheGameSigning.filesToSign(inBundle: bundle).map { $0.path.components(separatedBy: "/Game.app/").last! }.sorted()
    }

    func testZsignSignsTheFilesIOSLoadsCodeFromOnly() throws {
        XCTAssertEqual(signedFiles(in: try makeBundle()), Self.codeFiles.sorted())
    }

    /// What zsign gets is what a file's Mach-O header says, thin or
    /// universal, never its name or its folder: code under any name,
    /// anywhere in the bundle, and never a file named or put as code that
    /// holds none of the iPhone's.
    func testAFileIsSignedForItsHeaderNeverItsNameOrFolder() throws {
        let bundle = try makeBundle()
        try write(Self.machO(cpu: Self.arm64, fileType: 8), "Game.app/dm/renderer.dat")
        try write(Self.universal([(Self.x86_64, Self.machO(cpu: Self.x86_64, fileType: 6)),
                                  (Self.arm64, Self.machO(cpu: Self.arm64, fileType: 6))]), "Game.app/Assets/audio.png")
        try write(Data("// not code\n".utf8) + Data(repeating: 0x20, count: 4084), "Game.app/Frameworks/libnotes.dylib")
        try write(Data(repeating: 0, count: 4096), "Game.app/PlugIns/Empty.appex/Empty")
        try write(Self.machO(cpu: Self.gpu, fileType: 6), "Game.app/Frameworks/Shaders.framework/Shaders")
        try write(Self.machO(cpu: Self.x86_64, fileType: 2), "Game.app/Game.x86")
        XCTAssertEqual(signedFiles(in: bundle), (Self.codeFiles + ["dm/renderer.dat", "Assets/audio.png"]).sorted())
    }

    /// Breath of the Wild's install: zsign was handed the pipeline archive,
    /// which it cannot sign, and the whole signing failed.
    func testAMetalPipelineArchiveIsNeverSigned() throws {
        let archive = try write(Self.universal([(Self.gpu, Self.machO(cpu: Self.gpu, fileType: 2, bytes: 8192))]),
                                "pso/applegpu_g18p.mtl4a")
        XCTAssertFalse(CartoucheGameSigning.isSignable(at: archive))
        XCTAssertFalse(CartoucheGameSigning.isSignable(at: try write(Self.machO(cpu: Self.gpu, fileType: 2), "gpu.mtl4a")))
        // A universal file with a slice of the iPhone's among others is
        // signed, every slice with it, as zsign does.
        XCTAssertTrue(CartoucheGameSigning.isSignable(at: try write(Self.universal([
            (Self.gpu, Self.machO(cpu: Self.gpu, fileType: 6)), (Self.arm64, Self.machO(cpu: Self.arm64, fileType: 6)),
        ]), "mixed.dylib")))
    }

    func testAFileCutShortOrLyingIsNotSigned() throws {
        let whole = Self.universal([(Self.arm64, Self.machO(cpu: Self.arm64, fileType: 6, bytes: 8192))])
        XCTAssertTrue(CartoucheGameSigning.isSignable(at: try write(whole, "whole.dylib")))
        // Its slice ends past the end of the file.
        XCTAssertFalse(CartoucheGameSigning.isSignable(at: try write(whole.prefix(8192), "cut.dylib")))
        // Its list of slices ends past the end of the file.
        XCTAssertFalse(CartoucheGameSigning.isSignable(at: try write(whole.prefix(16), "header.dylib")))
        XCTAssertFalse(CartoucheGameSigning.isSignable(at: try write(Self.machO(cpu: Self.arm64, fileType: 2).prefix(20), "short")))
        XCTAssertFalse(CartoucheGameSigning.isSignable(at: try write(Data(), "empty")))
        XCTAssertFalse(CartoucheGameSigning.isSignable(at: folder.appendingPathComponent("missing")))
        // Its slice says arm64, but holds another processor's code.
        XCTAssertFalse(CartoucheGameSigning.isSignable(at: try write(Self.universal([(Self.arm64, Self.machO(cpu: Self.gpu, fileType: 2))]),
                                                                    "lying")))
        // Too many slices to be a universal file.
        var many = whole
        many.replaceSubrange(4..<8, with: [0, 0, 0, 33])
        XCTAssertFalse(CartoucheGameSigning.isSignable(at: try write(many, "many.dylib")))
    }

    func testTheListReadsAFileFromOffsets() {
        // A read that fails, or comes back short, signs nothing.
        let header = Self.machO(cpu: Self.arm64, fileType: 2)
        XCTAssertTrue(CartoucheGameSigning.isSignable(size: UInt64(header.count)) { offset, count in
            header.subdata(in: Int(offset)..<min(header.count, Int(offset) + count))
        })
        XCTAssertFalse(CartoucheGameSigning.isSignable(size: UInt64(header.count)) { _, _ in nil })
        XCTAssertFalse(CartoucheGameSigning.isSignable(size: UInt64(header.count)) { _, count in header.prefix(count - 1) })
    }

    // MARK: Why signing failed

    private let bundle = "/private/var/mobile/Containers/Data/Application/0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9/Documents/Applications/org.nxnative.01007ef00011e000.app"

    func testLiveContainersKeysGiveTheirReason() {
        let french = [
            "lc.signer.noCertificateFoundErr": "Aucun certificat trouvé.",
            "lc.signer.latestCertificateInvalidErr": "Le certificat n’est plus valide.",
            "lc.signer.crashDuringSignErr": "L’app s’est arrêtée pendant la signature.",
        ]
        for (key, reason) in [("lc.signer.noCertificateFoundErr", CartoucheGameSigning.Reason.noCertificate),
                              ("lc.signer.latestCertificateInvalidErr", .certificateRefused),
                              ("lc.signer.crashDuringSignErr", .interrupted)] {
            XCTAssertEqual(CartoucheGameSigning.failure(key).reason, reason)
            // As the player's language gives it.
            XCTAssertEqual(CartoucheGameSigning.failure(french[key]!, localized: { french[$0] ?? $0 }).reason, reason)
        }
        XCTAssertEqual(CartoucheGameSigning.failure("lc.signer.noCertificateFoundErr").reason.cause, .certificate)
        XCTAssertEqual(CartoucheGameSigning.failure("lc.signer.latestCertificateInvalidErr").reason.cause, .certificate)
        XCTAssertEqual(CartoucheGameSigning.failure("lc.signer.crashDuringSignErr").reason.cause, .notSigned)
    }

    /// What every install of Breath of the Wild said, its kind now.
    func testZsignsLinesGiveTheFilesAndTheirKindNeverTheirPath() {
        let archive = CartoucheGameSigning.failure("Failed to Sign " + bundle + "/pso/applegpu_g18p.mtl4a", executable: "BreathoftheWild")
        XCTAssertEqual(archive, CartoucheGameSigning.Failure(reason: .filesNotSigned, fileKind: "other", files: 1))
        XCTAssertEqual(archive.reason.cause, .notSigned)
        XCTAssertTrue(archive.reason.signingAgainHelps)

        // Several files, in the order zsign finished them: the kind of the
        // one most needed to start.
        let several = CartoucheGameSigning.failure([
            "Failed to Sign " + bundle + "/PlugIns/Widget.appex/Widget",
            "Failed to Sign " + bundle + "/Frameworks/MoltenVK.framework/MoltenVK",
            "Failed to Sign " + bundle + "/BreathoftheWild",
            "Invalid mach-o file! " + bundle + "/lib/libz.dylib",
        ].joined(separator: "\n"), executable: "BreathoftheWild")
        XCTAssertEqual(several, CartoucheGameSigning.Failure(reason: .filesNotSigned, fileKind: "executable", files: 4))
        XCTAssertEqual(CartoucheGameSigning.failure("Failed to Sign " + bundle + "/Frameworks/MoltenVK.framework/MoltenVK\n"
                                                    + "Failed to Sign " + bundle + "/PlugIns/Widget.appex/Widget").fileKind, "framework")
        XCTAssertEqual(CartoucheGameSigning.failure("Invalid mach-o file! " + bundle + "/lib/libz.dylib"),
                       CartoucheGameSigning.Failure(reason: .notMachO, fileKind: "library", files: 1))
        // Signed all the same, as LiveContainer may say.
        XCTAssertEqual(CartoucheGameSigning.failure("Failed to Sign " + bundle + "/PlugIns/Widget.appex/Widget", signed: true),
                       CartoucheGameSigning.Failure(reason: .filesNotSigned, fileKind: "plugIn", files: 1, signedAnyway: true))

        // Nothing of the path leaves the iPhone: names and numbers, which
        // the measurements keep whole.
        let details = several.details
        XCTAssertEqual(details, ["kind": .text("filesNotSigned"), "fileKind": .text("executable"), "files": .number(4)])
        XCTAssertEqual(CartoucheFailure(several.reason.cause, details: details).details, details)
        let partly = CartoucheGameSigning.Failure(reason: .filesNotSigned, fileKind: "plugIn", files: 1, signedAnyway: true)
        XCTAssertEqual(CartoucheFailure(.notSigned, details: partly.details).details, partly.details)
    }

    func testTheExecutableIsTheBundlesOwnFileOfItsName() {
        XCTAssertEqual(CartoucheGameSigning.fileKind(of: bundle + "/Game", executable: "Game"), "executable")
        XCTAssertEqual(CartoucheGameSigning.fileKind(of: "/var/x/Game.app/Game", executable: "Game"), "executable")
        // A file of that name elsewhere is not the game's executable.
        XCTAssertEqual(CartoucheGameSigning.fileKind(of: "/var/x/Game.app/tools/Game", executable: "Game"), "other")
        XCTAssertEqual(CartoucheGameSigning.fileKind(of: bundle + "/Game", executable: nil), "other")
        XCTAssertEqual(CartoucheGameSigning.fileKind(of: bundle + "/Extensions/Widget.appex/Widget", executable: "Game"), "plugIn")
        XCTAssertEqual(CartoucheGameSigning.fileKind(of: bundle + "/Frameworks/libc++.dylib", executable: "Game"), "library")
    }

    func testLiveContainersAndZsignsWordsGiveTheirReason() {
        let cases: [(String, CartoucheGameSigning.Reason)] = [
            ("Failed to load ZSign: dlopen(@executable_path/Frameworks/ZSign.dylib, 0x0008): tried: '/x' (no such file)", .signerMissing),
            ("Failed to initialize zSignAsset. Maybe wrong password?", .certificateUnreadable),
            ("The app you tried to install is encrypted. Please provide decrypted app.", .encrypted),
            ("Info.plist not found", .infoPlistMissing),
            ("Failed to map " + bundle + "/Game: Operation not permitted", .executableUnreadable),
            ("Failed to open " + bundle + "/Game: No such file or directory", .executableUnreadable),
            ("Not a Mach-O file", .executableUnreadable),
            ("Something else entirely", .other),
            ("", .other),
        ]
        for (message, reason) in cases {
            let failure = CartoucheGameSigning.failure(message)
            XCTAssertEqual(failure, CartoucheGameSigning.Failure(reason: reason), message)
        }
        XCTAssertEqual(CartoucheGameSigning.Reason.certificateUnreadable.cause, .certificate)
        XCTAssertEqual(CartoucheGameSigning.Reason.encrypted.cause, .notSigned)
        // Signing again never decrypts an app, nor mends its files.
        XCTAssertFalse(CartoucheGameSigning.Reason.encrypted.signingAgainHelps)
        XCTAssertFalse(CartoucheGameSigning.Reason.executableUnreadable.signingAgainHelps)
        XCTAssertFalse(CartoucheGameSigning.Reason.noCertificate.signingAgainHelps)
        // Not before Cartouche has taken the new certificate.
        XCTAssertFalse(CartoucheGameSigning.Reason.certificateRefused.signingAgainHelps)
        XCTAssertTrue(CartoucheGameSigning.Reason.interrupted.signingAgainHelps)
        // The kinds the measurements gave LiveContainer's own errors.
        XCTAssertEqual(CartoucheGameSigning.failure("lc.signer.noCertificateFoundErr").details["kind"], .text("noCertificateFound"))
        XCTAssertEqual(CartoucheGameSigning.failure("lc.signer.latestCertificateInvalidErr").details["kind"],
                       .text("latestCertificateInvalid"))
        XCTAssertEqual(CartoucheGameSigning.failure("lc.signer.crashDuringSignErr").details["kind"], .text("crashDuringSign"))
    }

    func testEveryReasonAndKindIsANameTheMeasurementsKeep() {
        for reason in CartoucheGameSigning.Reason.allCases {
            XCTAssertNotNil(CartoucheFailure.name(reason.rawValue), reason.rawValue)
        }
        for kind in CartoucheGameSigning.StartFailure.Kind.allCases {
            XCTAssertNotNil(CartoucheFailure.name(kind.rawValue), kind.rawValue)
        }
        for kind in CartoucheGameSigning.fileKinds {
            XCTAssertNotNil(CartoucheFailure.name(kind), kind)
        }
    }

    // MARK: Why the game's process ended on an error

    func testLiveProcesssWordsGiveWhyTheGameDidNotStart() {
        let game = bundle + "/BreathoftheWild"
        let cases: [(String, CartoucheGameSigning.StartFailure.Kind)] = [
            ("dlopen(" + game + ", 0x0009): tried: '" + game + "' (code signature invalid in <D3B1F3C2-9C1A-3B6E-8F0A-2C4D5E6F7A8B> '"
                + game + "' (errno=1) sliceOffset=0x00000000, codeBlobOffset=0x0A4B2C30, codeBlobSize=0x0012F4A0)", .codeSignature),
            ("dlopen(" + game + ", 0x0009): Library not loaded: @rpath/MoltenVK.framework/MoltenVK\n  Referenced from: <UUID> " + game
                + "\n  Reason: tried: '" + bundle + "/Frameworks/MoltenVK.framework/MoltenVK' (code signature in <UUID> '"
                + bundle + "/Frameworks/MoltenVK.framework/MoltenVK' not valid for use in process: Trust evaluation failed)", .codeSignature),
            ("dlopen(" + game + ", 0x0009): Library not loaded: @rpath/MoltenVK.framework/MoltenVK\n  Referenced from: <UUID> " + game
                + "\n  Reason: tried: '" + bundle + "/Frameworks/MoltenVK.framework/MoltenVK' (no such file)", .libraryMissing),
            ("dlopen(" + game + ", 0x0009): Symbol not found: _MTLCreateSystemDefaultDevice\n  Referenced from: <UUID> " + game,
             .symbolMissing),
            ("dlopen(" + game + ", 0x0009): tried: '" + game + "' (mach-o file, but is an incompatible architecture (have 'x86_64', need 'arm64e' or 'arm64'))",
             .architecture),
            ("dlopen(" + game + ", 0x0009): tried: '" + game + "' (no such file)", .fileMissing),
            ("App's executable path not found. Please try force re-signing or reinstalling this app.", .fileMissing),
            ("App bundle not found! Unable to read LCAppInfo.plist.", .fileMissing),
            ("Could not find the main entry point", .noEntryPoint),
            ("*** -[__NSArrayM objectAtIndex:]: index 3 beyond bounds [0 .. 1]\nCall stack: (\n0 CoreFoundation 0x1)", .exception),
            ("Failed to start app. Child process has unexpectedly crashed", .crashedAtStart),
            ("JITLess mode is required since iOS 26. Please set it up in settings.", .jitRequired),
            ("JIT was not enabled. If you want to use LiveContainer without JIT, setup JITLess mode in settings.", .jitRequired),
            ("Container not found!", .containerMissing),
            ("dlopen: an unknown error occurred", .other),
        ]
        for (message, kind) in cases {
            XCTAssertEqual(CartoucheGameSigning.startFailure(message), CartoucheGameSigning.StartFailure(kind: kind), message)
        }
        XCTAssertEqual(CartoucheGameSigning.startFailure("App returned from its main function with code 1."),
                       CartoucheGameSigning.StartFailure(kind: .returnedFromMain, code: 1))
        XCTAssertEqual(CartoucheGameSigning.startFailure("App returned from its main function with code -6."),
                       CartoucheGameSigning.StartFailure(kind: .returnedFromMain, code: -6))

        let signature = CartoucheGameSigning.startFailure("tried: 'x' (code signature invalid in <x> 'x' (errno=1))")
        XCTAssertEqual(signature.cause, .notSigned)
        XCTAssertTrue(signature.signingAgainHelps)
        let returned = CartoucheGameSigning.startFailure("App returned from its main function with code 1.")
        XCTAssertEqual(returned.cause, .gameEndedOnError)
        XCTAssertFalse(returned.signingAgainHelps)
        XCTAssertEqual(returned.details, ["kind": .text("returnedFromMain"), "code": .number(1)])
        XCTAssertEqual(CartoucheFailure(returned.cause, details: returned.details).details, returned.details)
    }
}
