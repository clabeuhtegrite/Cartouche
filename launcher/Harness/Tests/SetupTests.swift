//
//  SetupTests.swift
//  CartoucheHarnessTests
//
//  What Cartouche needs before it plays games, and does on its own
//  (CartoucheSetup.swift): the certificate the built-in SideStore keeps in
//  its keychain goes to LiveContainer, Cartouche checks that iOS runs what
//  it signs, and the pairing file the player gives goes where SideStore
//  reads it.
//

import Security
import XCTest
@testable import CartoucheHarness

final class SetupTests: HarnessCase {
    /// Leaves CERTIFICATE in the built-in SideStore's keychain, as it keeps
    /// it once the player signed in.
    private func storeKeeps(_ certificate: HarnessCertificate, password: String? = nil,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(CartoucheStoreKeychain.set(certificate.data, for: "signingCertificate"),
                      "the keychain works in the harness", file: file, line: line)
        XCTAssertTrue(CartoucheStoreKeychain.set(Data((password ?? certificate.password).utf8), for: "signingCertificatePassword"),
                      file: file, line: line)
    }

    // MARK: The certificate

    func testSideStoresCertificateGoesToLiveContainer() async throws {
        HarnessLC.installCertificate(nil)
        XCTAssertFalse(CartoucheCertificate.isInstalled)
        let fromStore = HarnessCertificate(team: "STORE00001", password: "sidestore", serial: 4)
        storeKeeps(fromStore)

        XCTAssertTrue(CartoucheCertificate.handOff())
        XCTAssertTrue(CartoucheCertificate.isInstalled)
        XCTAssertEqual(LCUtils.certificateData(), fromStore.data)
        XCTAssertEqual(LCSharedUtils.certificatePassword(), "sidestore")
        XCTAssertNotNil(LCUtils.appGroupUserDefault.object(forKey: "LCCertificateUpdateDate"))

        // Games are signed with it from now on.
        let app = try await installed(.plain())
        XCTAssertTrue(HarnessLC.signatureIsValid(try bundle(of: app).appendingPathComponent(HarnessGame.plain().executable).path))
    }

    func testANewCertificateOfSideStoreTakesThePlaceOfLiveContainers() {
        let newer = HarnessCertificate(team: "HARNESS001", password: "harness", serial: 99)
        storeKeeps(newer)
        XCTAssertTrue(CartoucheCertificate.handOff())
        XCTAssertEqual(LCUtils.certificateData(), newer.data)
    }

    func testACertificateWhoseKeyDoesNotOpenIsNotHandedOff() {
        let mine = certificate
        storeKeeps(HarnessCertificate(team: "STORE00001", password: "right", serial: 5), password: "wrong")
        XCTAssertTrue(CartoucheCertificate.handOff(), "LiveContainer keeps the one it has")
        XCTAssertEqual(LCUtils.certificateData(), mine.data)

        HarnessLC.installCertificate(nil)
        XCTAssertFalse(CartoucheCertificate.handOff(), "and has none without one")
        XCTAssertNil(LCUtils.certificateData())
    }

    func testWithoutSideStoresCertificateLiveContainersStays() {
        XCTAssertTrue(CartoucheCertificate.handOff())
        XCTAssertEqual(LCUtils.certificateData(), certificate.data)
    }

    func testCartoucheAsksIOSWhetherTheCertificateWorks() async {
        let works = await CartoucheCertificate.works()
        XCTAssertTrue(works)
        HarnessLC.iOSRefusesCertificate = true
        let refused = await CartoucheCertificate.works()
        XCTAssertFalse(refused)
    }

    func testTheSetupFindsTheCertificateAndChecksItOnce() async throws {
        let setup = CartoucheSetup.shared
        setup.refresh()
        XCTAssertTrue(setup.hasCertificate)
        try await waitUntil("Cartouche knows whether the certificate works") { setup.certificateWorks != nil }
        XCTAssertEqual(setup.certificateWorks, true)
        XCTAssertTrue(setup.canPlay)
        XCTAssertFalse(setup.certificateRefused)

        // Known for this launch: no other check.
        HarnessLC.iOSRefusesCertificate = true
        setup.refresh()
        XCTAssertEqual(setup.certificateWorks, true)
    }

    func testTheSetupSaysWhenIOSRefusesTheCertificate() async throws {
        HarnessLC.iOSRefusesCertificate = true
        let setup = CartoucheSetup.shared
        setup.refresh()
        try await waitUntil("Cartouche knows whether the certificate works") { setup.certificateWorks != nil }
        XCTAssertEqual(setup.certificateWorks, false)
        XCTAssertTrue(setup.certificateRefused)
        XCTAssertFalse(setup.canPlay)
        XCTAssertTrue(setup.needsSetup)
    }

    func testWithoutACertificateNoGameCanStart() async throws {
        HarnessLC.installCertificate(nil)
        let setup = CartoucheSetup.shared
        setup.refresh()
        XCTAssertFalse(setup.hasCertificate)
        XCTAssertNil(setup.certificateWorks)
        XCTAssertFalse(setup.canPlay)
    }

    // MARK: The Apple ID

    func testTheAppleIDIsTheOneSideStoreSignedInWith() {
        XCTAssertTrue(CartoucheStoreKeychain.set(Data("player@example.com".utf8), for: "appleIDEmailAddress"))
        CartoucheSetup.shared.refresh()
        XCTAssertEqual(CartoucheSetup.shared.appleID, "player@example.com")
        CartoucheStoreKeychain.remove("appleIDEmailAddress")
        CartoucheSetup.shared.refresh()
        XCTAssertNil(CartoucheSetup.shared.appleID)
    }

    // MARK: The pairing file

    /// A pairing file as iloader exports one: lockdown's keys, made up.
    private func pairingFile() -> Data {
        var plist: [String: Any] = [:]
        for key in ["WiFiMACAddress", "SystemBUID", "HostID", "UDID"] {
            plist[key] = "HARNESS-" + key
        }
        for key in ["RootPrivateKey", "HostPrivateKey", "RootCertificate", "EscrowBag", "HostCertificate", "DeviceCertificate"] {
            plist[key] = Data(key.utf8)
        }
        return HarnessIPA.plist(plist)
    }

    private var storePairingFile: URL {
        CartouchePairing.storeDocuments.appendingPathComponent(CartouchePairing.importName)
    }

    func testAPairingFileDroppedOnCartoucheGoesWhereSideStoreReadsIt() throws {
        let dropped = LCPath.docPath.appendingPathComponent("iPhone.mobiledevicepairing")
        try pairingFile().write(to: dropped)
        let other = LCPath.docPath.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: other)

        XCTAssertFalse(CartouchePairing.exists)
        XCTAssertTrue(CartouchePairing.takeDroppedFile())
        XCTAssertEqual(try Data(contentsOf: storePairingFile), pairingFile())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.path), "it moves")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "other files stay")
        XCTAssertTrue(CartouchePairing.exists)
        CartoucheSetup.shared.refresh()
        XCTAssertTrue(CartoucheSetup.shared.hasPairingFile)
    }

    func testAFileThatIsNoPairingFileIsRefusedAndSaysWhy() throws {
        let file = HarnessIPA.folder.appendingPathComponent("Photo.plist")
        try FileManager.default.createDirectory(at: HarnessIPA.folder, withIntermediateDirectories: true)
        try HarnessIPA.plist(["CFBundleIdentifier": "com.example.photo"]).write(to: file)

        let setup = CartoucheSetup.shared
        setup.importPairingFile(file)
        XCTAssertEqual(setup.pairingError, CartoucheText.setupPairingInvalid)
        XCTAssertNotNil(setup.pairingReport)
        XCTAssertFalse(CartouchePairing.exists)
        XCTAssertFalse(setup.hasPairingFile)

        // A good one clears the report.
        let good = HarnessIPA.folder.appendingPathComponent("iPhone.mobiledevicepairing")
        try pairingFile().write(to: good)
        setup.importPairingFile(good)
        XCTAssertNil(setup.pairingReport)
        XCTAssertTrue(setup.hasPairingFile)
    }

    func testAPairingFileOpenedFromAnotherAppShowsTheSetup() throws {
        let file = HarnessIPA.folder.appendingPathComponent("iPhone.mobiledevicepairing")
        try FileManager.default.createDirectory(at: HarnessIPA.folder, withIntermediateDirectories: true)
        try pairingFile().write(to: file)
        CartoucheSetup.shared.openedPairingFile = false
        XCTAssertTrue(CartouchePairing.openedFile(file))
        XCTAssertTrue(CartoucheSetup.shared.openedPairingFile)
        XCTAssertTrue(CartouchePairing.exists)
        CartoucheSetup.shared.openedPairingFile = false
    }

    func testAFileOfAnotherKindIsNotCartouchesToTake() throws {
        let file = HarnessIPA.folder.appendingPathComponent("Song.mp3")
        try FileManager.default.createDirectory(at: HarnessIPA.folder, withIntermediateDirectories: true)
        try Data("ID3".utf8).write(to: file)
        XCTAssertFalse(CartouchePairing.openedFile(file))
        XCTAssertNil(actions.work)
    }
}
