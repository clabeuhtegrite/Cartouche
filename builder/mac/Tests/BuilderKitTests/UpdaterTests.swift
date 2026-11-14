//
//  UpdaterTests.swift
//  BuilderKitTests
//
//  The app's updates (Updater.swift): which release of GitHub's it takes,
//  the versions it compares, the SHA-256 it checks, and the new app it
//  accepts in place of its own.
//

import Foundation
import XCTest
@testable import BuilderKit

final class UpdaterTests: XCTestCase {
    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, files: [String]? = nil,
                         host: String = "https://github.com/clabeuhtegrite/Cartouche/releases/download") -> [String: Any] {
        let version = tag.hasPrefix("builder-v") ? String(tag.dropFirst("builder-v".count)) : tag
        let names = files ?? ["Cartouche-Builder-\(version).dmg", "Cartouche-Builder-\(version).dmg.sha256"]
        return [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "body": "What \(tag) brings.",
            "html_url": "https://github.com/clabeuhtegrite/Cartouche/releases/tag/\(tag)",
            "assets": names.map { ["name": $0, "browser_download_url": "\(host)/\(tag)/\($0)", "size": $0.hasSuffix(".dmg") ? 41_234_567 : 97] },
        ]
    }

    func testTheNewestReleaseIsTheBuildersWithItsImageAndChecksum() throws {
        let releases: [[String: Any]] = [
            release("builder-v0.3.0", draft: true),
            release("builder-v0.2.9", prerelease: true),
            release("v0.10.0", files: ["Cartouche-0.10.0.ipa"]),
            release("installer-v0.4.0", files: ["Cartouche-Installer-0.4.0-Mac.dmg"]),
            release("builder-v0.2.5", files: ["Cartouche-Builder-0.2.5.dmg"]),
            release("builder-v0.2.4", host: "https://example.com/clabeuhtegrite/Cartouche/releases/download"),
            release("builder-v0.2.3", host: "https://github.com/someone-else/Cartouche/releases/download"),
            release("builder-vnext"),
            release("builder-v0.2.1"),
            release("builder-v0.2.0"),
        ]
        let data = try JSONSerialization.data(withJSONObject: releases)
        let newest = try XCTUnwrap(try BuilderReleases.newest(in: data))
        XCTAssertEqual(newest.version, "0.2.1")
        XCTAssertEqual(newest.tag, "builder-v0.2.1")
        XCTAssertEqual(newest.notes, "What builder-v0.2.1 brings.")
        XCTAssertEqual(newest.size, 41_234_567)
        XCTAssertEqual(newest.image.lastPathComponent, "Cartouche-Builder-0.2.1.dmg")
        XCTAssertEqual(newest.checksum.lastPathComponent, "Cartouche-Builder-0.2.1.dmg.sha256")
        XCTAssertEqual(newest.page.absoluteString, "https://github.com/clabeuhtegrite/Cartouche/releases/tag/builder-v0.2.1")

        XCTAssertNil(try BuilderReleases.newest(in: Data("[]".utf8)))
        XCTAssertThrowsError(try BuilderReleases.newest(in: Data("{\"message\": \"API rate limit exceeded\"}".utf8)))
    }

    func testAMovedRepositorysReleasesComeFromWhereGitHubAnswered() throws {
        // GitHub redirects the API of a repository that moved to an
        // organization, and its answer gives the new place's addresses.
        let moved = "https://github.com/new-owner/Cartouche/releases/download"
        let releases: [[String: Any]] = [
            release("builder-v0.4.0", host: "https://github.com/someone-else/Cartouche/releases/download"),
            release("builder-v0.3.0", host: moved),
            release("builder-v0.2.0"),
        ]
        let data = try JSONSerialization.data(withJSONObject: releases)
        XCTAssertEqual(try XCTUnwrap(try BuilderReleases.newest(in: data)).version, "0.2.0")

        let answering = BuilderReleases.answeringRepository(URL(string: "https://api.github.com/repos/new-owner/Cartouche/releases?per_page=40"))
        XCTAssertEqual(answering, "new-owner/Cartouche")
        let newest = try XCTUnwrap(try BuilderReleases.newest(in: data, answering: answering))
        XCTAssertEqual(newest.version, "0.3.0")
        XCTAssertEqual(newest.image.absoluteString, moved + "/builder-v0.3.0/Cartouche-Builder-0.3.0.dmg")

        XCTAssertEqual(BuilderReleases.answeringRepository(BuilderReleases.api), BuilderReleases.repository)
        for other in ["http://api.github.com/repos/a/b/releases", "https://example.com/repos/a/b/releases",
                      "https://api.github.com/repos/a/b/tags", "https://api.github.com/repos/a/releases"] {
            XCTAssertNil(BuilderReleases.answeringRepository(URL(string: other)), other)
        }
        XCTAssertNil(BuilderReleases.answeringRepository(nil))
    }

    func testVersions() {
        XCTAssertEqual(BuilderVersion.parts("0.2.0"), [0, 2, 0])
        XCTAssertEqual(BuilderVersion.parts("26"), [26])
        for odd in ["", "v0.2", "0..2", "0.2.", "1.2.3.4.5", "0.2-beta", "１.２"] {
            XCTAssertNil(BuilderVersion.parts(odd), odd)
        }
        XCTAssertTrue(BuilderVersion.isHigher("0.10.0", than: "0.9.9"))
        XCTAssertTrue(BuilderVersion.isHigher("0.2.1", than: "0.2"))
        XCTAssertFalse(BuilderVersion.isHigher("0.2", than: "0.2.0"))
        XCTAssertFalse(BuilderVersion.isHigher("0.2.0", than: "0.2.1"))
        XCTAssertFalse(BuilderVersion.isHigher("next", than: "0.2.0"))
    }

    func testChecksums() throws {
        let sum = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
        XCTAssertEqual(BuilderReleases.checksum(in: "\(sum)  Cartouche-Builder-0.2.1.dmg\n"), sum.lowercased())
        XCTAssertNil(BuilderReleases.checksum(in: ""))
        XCTAssertNil(BuilderReleases.checksum(in: "ba7816bf  Cartouche-Builder-0.2.1.dmg"))
        XCTAssertNil(BuilderReleases.checksum(in: String(repeating: "z", count: 64)))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("Cartouche-Builder-0.2.1.dmg")
        try Data("abc".utf8).write(to: image)
        XCTAssertEqual(try Updater.sha256(of: image), sum.lowercased())
        try Data("\(sum)  Cartouche-Builder-0.2.1.dmg\n".utf8).write(to: image.appendingPathExtension("sha256"))
        XCTAssertTrue(try Updater.verify(image))
        try Data("abd".utf8).write(to: image)
        XCTAssertFalse(try Updater.verify(image))
    }

    func testTheNewAppMustBeCartoucheBuilderAtTheReleasesVersion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func app(_ info: [String: Any]) throws -> URL {
            let app = folder.appendingPathComponent(UUID().uuidString + ".app", isDirectory: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
        let identifier = "io.github.clabeuhtegrite.cartouche-builder"
        let good = try app(["CFBundleIdentifier": identifier, "CFBundleShortVersionString": "0.2.1", "LSMinimumSystemVersion": "26.0"])
        XCTAssertNoThrow(try Updater.check(good, version: "0.2.1", identifier: identifier))
        XCTAssertThrowsError(try Updater.check(good, version: "0.2.2", identifier: identifier))
        let other = try app(["CFBundleIdentifier": "com.example.other", "CFBundleShortVersionString": "0.2.1"])
        XCTAssertThrowsError(try Updater.check(other, version: "0.2.1", identifier: identifier))
        let later = try app(["CFBundleIdentifier": identifier, "CFBundleShortVersionString": "0.2.1", "LSMinimumSystemVersion": "99.0"])
        XCTAssertThrowsError(try Updater.check(later, version: "0.2.1", identifier: identifier))
        XCTAssertThrowsError(try Updater.check(folder.appendingPathComponent("Missing.app"), version: "0.2.1", identifier: identifier))
    }

    @MainActor
    func testAnUpdateWaitsForTheBuildAndForTheApplicationsFolder() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let release = BuilderRelease(version: "0.2.1", tag: "builder-v0.2.1", notes: "", page: URL(string: "https://github.com/")!,
                                     image: URL(string: "https://github.com/a.dmg")!, checksum: URL(string: "https://github.com/a.dmg.sha256")!, size: 1)
        let fromImage = Updater(app: URL(fileURLWithPath: "/Volumes/Cartouche Builder/Cartouche Builder.app"), version: "0.2.0",
                                identifier: Updater.identifier, folder: folder, enabled: true)
        XCTAssertTrue(fromImage.runsFromDiskImage)
        fromImage.preview(.ready(release))
        XCTAssertFalse(fromImage.installsAtQuit)

        let installed = Updater(app: folder.appendingPathComponent("Cartouche Builder.app"), version: "0.2.0",
                                identifier: Updater.identifier, folder: folder, enabled: true)
        XCTAssertFalse(installed.runsFromDiskImage)
        XCTAssertFalse(installed.installsAtQuit)
        installed.preview(.ready(release))
        XCTAssertTrue(installed.isReady)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(installed.installsAtQuit)
        var building = true
        installed.isBuilding = { building }
        XCTAssertFalse(installed.installsAtQuit)
        building = false
        XCTAssertTrue(installed.installsAtQuit)

        let fromTerminal = Updater(app: URL(fileURLWithPath: "/Volumes/x/python3"), version: "0.2.0", identifier: "", folder: folder, enabled: false)
        XCTAssertFalse(fromTerminal.runsFromDiskImage)
    }
}
