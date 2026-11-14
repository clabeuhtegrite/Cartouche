//
//  CartoucheSetup.swift
//  Cartouche
//
//  Imported signing is an alternative to the account setup below: the
//  installer or the setup's import screen supplies a P12 and profile, the
//  keychain keeps them, and no Apple ID, pairing file or VPN is needed for
//  playing. CartoucheImportedSigning manages that selection and validation.
//
//  What Cartouche needs before it plays games and renews itself, and what it
//  does on its own:
//
//  - The certificate. The Cartouche Installer (installer/), as iloader, puts
//    its signing certificate inside the built-in SideStore when it installs
//    Cartouche (app/scripts/brand.py says why), and SideStore takes it into
//    its keychain once the player signs in with their Apple ID. Cartouche
//    then hands it to LiveContainer, which signs each game with it: no
//    button, no file, every time Cartouche comes to the front. Cartouche
//    then checks that iOS runs what it signs: an install from another
//    computer can revoke the one SideStore keeps, and Cartouche then has
//    SideStore sign in again, which takes the installer's new one.
//  - The pairing file, which only a computer can make: SideStore needs it to
//    install and renew apps. The Cartouche Installer puts it where the
//    built-in SideStore reads it when it installs Cartouche. iloader exports
//    it, and the player drops it on Cartouche in Apple Devices, iTunes or the
//    Finder, opens it with Cartouche, or chooses it in the setup: it goes to
//    the same place. iloader places it there by itself only in the apps it
//    lists by name, and Cartouche is not one (app/README.md says why).
//  - The Apple ID, which the player gives on Cartouche's own screen
//    (CartoucheAccount): the built-in SideStore signs in with it, without
//    showing itself, registers this iPhone with the account, then renews
//    Cartouche with it every week. A sign-in that Apple accepted can still
//    stop at the step that registers the iPhone: that step is left alone,
//    which Cartouche takes by itself once LocalDevVPN connects. It can also
//    stop before SideStore takes the certificate, at the team's step or the
//    certificate's, and SideStore keeps the Apple ID all the same: an Apple
//    ID without a certificate is a sign-in that stopped before it
//    (CartoucheSignInStep). The setup says so, and why, and SideStore signs
//    in again by itself, once, after Cartouche is installed again
//    (CartoucheAccount.resumeSignIn).
//  - LocalDevVPN, from the App Store, through which SideStore reaches the
//    iPhone's own services when it signs in and renews Cartouche.
//

import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

/// The built-in SideStore's keychain items. SideStore names its keychain
/// service after the bundle identifier SideStoreHooks gives it, Cartouche's
/// own without the team suffix that signing adds, which app/scripts/package.sh
/// writes into the Info.plist; the items sit in the keychain group the
/// installer gives Cartouche, as iloader does.
enum CartoucheStoreKeychain {
    static var service: String? {
        Bundle.main.object(forInfoDictionaryKey: "CartoucheBundleIdentifier") as? String
    }

    static func data(_ account: String) -> Data? {
        guard let service else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func string(_ account: String) -> String? {
        data(account).flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Leaves DATA for the built-in SideStore under ACCOUNT, in place of what
    /// was there, readable once the iPhone has been unlocked since it started,
    /// and on this iPhone only. Returns whether it is there.
    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        guard let service else { return false }
        remove(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ account: String) {
        guard let service else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum CartoucheCertificate {
    /// Whether LiveContainer has a certificate to sign games with.
    static var isInstalled: Bool { LCSharedUtils.certificatePassword() != nil && LCUtils.certificateData() != nil }

    /// Gives LiveContainer the built-in SideStore's certificate, when it has
    /// none or another one, as LiveContainer's "Import Certificate from
    /// SideStore" does after its confirmation: SideStore keeps the certificate
    /// that signs Cartouche, so the games follow it. Returns whether
    /// LiveContainer has a certificate now.
    @discardableResult
    static func handOff() -> Bool {
        if CartoucheImportedSigning.isSelected {
            return CartoucheImportedSigning.material != nil && isInstalled
        }
        guard let data = CartoucheStoreKeychain.data("signingCertificate") else { return isInstalled }
        let password = CartoucheStoreKeychain.data("signingCertificatePassword")
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if LCUtils.certificateData() == data && LCSharedUtils.certificatePassword() == password {
            return true
        }
        // A certificate whose private key does not open would only make every
        // launch fail: keep what LiveContainer has.
        guard LCUtils.getCertTeamId(withKeyData: data, password: password) != nil else { return isInstalled }
        let defaults = LCUtils.appGroupUserDefault
        defaults.set(data, forKey: "LCCertificateData")
        defaults.set(password, forKey: "LCCertificatePassword")
        defaults.set(Date(), forKey: "LCCertificateUpdateDate")
        return true
    }

    /// The certificate LiveContainer signs games with, to tell a new one.
    static var current: Data? { LCUtils.certificateData() }

    /// Whether iOS runs what LiveContainer signs with its certificate, as
    /// LiveContainer's own test of its setup checks: it signs a small library
    /// and asks iOS. A certificate Apple has revoked, as the installer does
    /// with an old one when the account has too many, fails it, and so would
    /// every game, with "the app is signed with the latest certificate but
    /// its signature is invalid".
    private static let probeQueue = DispatchQueue(label: "io.github.clabeuhtegrite.cartouche.certificateProbe", qos: .userInitiated)

    static func works(candidate: CartoucheSigningMaterial? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            probeQueue.async {
                let finished = DispatchSemaphore(value: 0)
                if let candidate {
                    LCSharedUtils.setCartoucheSigningCandidate([
                        "certificate": candidate.certificate, "password": candidate.password
                    ])
                }
                LCUtils.validateJITLessSetup { success, _ in
                    // The native probe deletes its test library after this
                    // callback. Finish on the next main-queue turn before
                    // allowing another probe to use the same temporary file.
                    DispatchQueue.main.async {
                        if candidate != nil { LCSharedUtils.setCartoucheSigningCandidate(nil) }
                        continuation.resume(returning: success)
                        finished.signal()
                    }
                }
                finished.wait()
            }
        }
    }
}

enum CartouchePairing {
    /// The built-in SideStore's Documents folder: LiveContainer gives it the
    /// SideStore folder of its own Documents as its home.
    static var storeDocuments: URL {
        LCPath.docPath.appendingPathComponent("SideStore/Documents", isDirectory: true)
    }

    /// The names SideStore reads a pairing file under (PairingFileManager).
    static let fileNames = ["PairingFile_RemoteRP.plist", "PairingFile_Lockdown.plist", "ALTPairingFile.mobiledevicepairing"]
    /// The one the installer writes, as iloader does for a
    /// LiveContainer+SideStore. SideStore works out which kind of pairing
    /// file it is when it reads it.
    static let importName = "ALTPairingFile.mobiledevicepairing"

    static var exists: Bool {
        fileNames.contains { FileManager.default.fileExists(atPath: storeDocuments.appendingPathComponent($0).path) }
    }

    /// The extensions of a pairing file iloader exports.
    static let fileExtensions = ["mobiledevicepairing", "mobiledevicepair", "plist"]

    static var contentTypes: [UTType] {
        var types = fileExtensions.compactMap { UTType(filenameExtension: $0) }
        types.append(contentsOf: [.propertyList, .xml, .data])
        return types
    }

    /// A file another app opened Cartouche with, from AirDrop or Files
    /// (app/patches/livecontainer/0004): whether it is Cartouche's to take,
    /// by its extension. The setup checks a pairing file and shows what came
    /// of it; Cartouche installs an IPA on its own screens, as Import does.
    @MainActor
    static func openedFile(_ url: URL) -> Bool {
        if #available(iOS 17.0, *), CartoucheGameActions.takes(url) {
            CartoucheGameActions.shared.install(url)
            return true
        }
        guard fileExtensions.contains(url.pathExtension.lowercased()) else { return false }
        CartoucheSetup.shared.importOpenedPairingFile(url)
        return true
    }

    enum Failure: LocalizedError {
        case notAPairingFile

        var errorDescription: String? { CartoucheText.setupPairingInvalid }
    }

    /// The keys of the two kinds of pairing file SideStore reads
    /// (minimuxer's PairingFile.swift).
    private static let remoteKeys = ["private_key", "public_key", "identifier"]
    private static let lockdownKeys = [
        "WiFiMACAddress", "SystemBUID", "RootPrivateKey", "HostPrivateKey", "HostID",
        "RootCertificate", "UDID", "EscrowBag", "HostCertificate", "DeviceCertificate",
    ]

    /// Takes a pairing file the player dropped into Cartouche from their
    /// computer: Apple Devices, iTunes and the Finder list Cartouche among the
    /// apps that share files, and put what is dropped on it at the top of its
    /// Documents, which the Files app shows as well. The file moves to where
    /// SideStore reads it, replacing the one SideStore had. Other files stay.
    /// Returns whether it took one.
    @discardableResult
    static func takeDroppedFile() -> Bool {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        // Files opened from Mail can also land in Inbox.
        for folder in [LCPath.docPath, LCPath.docPath.appendingPathComponent("Inbox", isDirectory: true)] {
            guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                    options: .skipsHiddenFiles) else { continue }
            let named = files.filter { fileExtensions.contains($0.pathExtension.lowercased()) }
            for file in named.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // A pairing file is a few kilobytes.
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, (values.fileSize ?? 0) < 1_048_576 else { continue }
                do {
                    try importFile(at: file)
                } catch {
                    continue
                }
                try? fileManager.removeItem(at: file)
                return true
            }
        }
        return false
    }

    /// Copies a pairing file the player picked, once it reads as one.
    static func importFile(at url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              remoteKeys.allSatisfy({ plist[$0] != nil }) || lockdownKeys.allSatisfy({ plist[$0] != nil }) else {
            throw Failure.notAPairingFile
        }
        try FileManager.default.createDirectory(at: storeDocuments, withIntermediateDirectories: true)
        try data.write(to: storeDocuments.appendingPathComponent(importName), options: .atomic)
    }
}

/// Where Cartouche stands, for the setup screen and the games' banner.
@MainActor
final class CartoucheSetup: ObservableObject {
    static let shared = CartoucheSetup()

    @Published private(set) var hasCertificate = false
    /// Whether iOS runs what LiveContainer signs with that certificate: nil
    /// until Cartouche has checked, once per certificate and launch.
    @Published private(set) var certificateWorks: Bool?
    @Published private(set) var hasPairingFile = false
    @Published private(set) var appleID: String?
    @Published private(set) var usesImportedSigning = CartoucheImportedSigning.isSelected
    @Published private(set) var isImportingSigning = false
    @Published private(set) var signingProblem: String?
    /// Whether a sign-in that Apple accepted stopped at the step that
    /// registers this iPhone with the account, which is left alone
    /// (CartoucheAccount.registerDevice). Kept across launches.
    @Published private(set) var deviceStepLeft = UserDefaults.standard.bool(forKey: CartoucheSetup.deviceStepKey)
    /// Why the last pairing file given to Cartouche was refused, and the
    /// report on it.
    @Published private(set) var pairingReport: CartoucheReport?
    var pairingError: String? { pairingReport?.message }
    /// Set when another app opens Cartouche with a pairing file, so that the
    /// games show the setup and what came of it.
    @Published var openedPairingFile = false

    /// Games start once LiveContainer has the certificate, and it works.
    var canPlay: Bool { !isImportingSigning && hasCertificate && certificateWorks != false }
    /// LiveContainer has a certificate that iOS no longer accepts.
    var certificateRefused: Bool { hasCertificate && certificateWorks == false }
    /// Cartouche also renews and updates itself once SideStore has the
    /// pairing file and is signed in, and the certificate is known to work:
    /// an update signed with a revoked one would not open.
    var isComplete: Bool { hasCertificate && certificateWorks == true && (usesImportedSigning || (hasPairingFile && appleID != nil)) }
    /// Signed in, with this iPhone left to register: never with the
    /// player's own certificate, which has no Apple ID.
    var needsDevice: Bool { !usesImportedSigning && deviceStepLeft && appleID != nil }
    /// Whether the setup has something left for the player: a certificate
    /// still being checked does not show it.
    var needsSetup: Bool { !(canPlay && (usesImportedSigning || (hasPairingFile && appleID != nil))) || needsDevice }
    /// What the measurements say of the installation (CartoucheSetupFacts.swift).
    var facts: CartoucheSetupFacts {
        CartoucheSetupFacts(hasCertificate: hasCertificate, certificateWorks: certificateWorks,
                            hasPairingFile: hasPairingFile, signedIn: appleID != nil)
    }
    /// Where the sign-in stands: SideStore keeps the Apple ID of a sign-in
    /// that stopped before the certificate. With the player's own
    /// certificate, Cartouche signs in to no Apple ID.
    var signInStep: CartoucheSignInStep { usesImportedSigning ? .notSignedIn : facts.signInStep }

    private static let deviceStepKey = "CartoucheDeviceStepLeft"

    /// What Cartouche found of each certificate, for this launch.
    private var checked: [Data: Bool] = [:]
    private var checking: Data?
    /// The refused certificates SideStore was asked to replace, once each.
    private var replacing: Set<Data> = []
    private var tookSigningHandoff = false

    private init() {
        refresh()
    }

    /// Reads everything again, after handing SideStore's certificate to
    /// LiveContainer: call it each time Cartouche comes to the front, since
    /// the player signs in from SideStore.
    func refresh() {
        guard !isImportingSigning else { return }
        usesImportedSigning = CartoucheImportedSigning.isSelected
        let handoff = LCPath.docPath.appendingPathComponent(CartoucheImportedSigning.handoffName)
        if CartoucheImportedSigning.isImportedInstall, !tookSigningHandoff,
           FileManager.default.fileExists(atPath: handoff.path) {
            tookSigningHandoff = true
            isImportingSigning = true
            Task {
                do {
                    guard let key = Bundle.main.object(forInfoDictionaryKey: "CartoucheSigningHandoffKey") as? Data,
                          let size = try handoff.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 9 * 1024 * 1024 else {
                        throw CartoucheImportedSigning.ImportError(message: CartoucheText.signingHandoffFailed, kind: "handoff")
                    }
                    let data = try Data(contentsOf: handoff)
                    let material: CartoucheSigningMaterial
                    do { material = try CartoucheSigningMaterial.openHandoff(data, key: key) }
                    catch { throw CartoucheImportedSigning.ImportError(message: CartoucheText.signingHandoffFailed, kind: "handoff") }
                    try await CartoucheImportedSigning.importMaterial(material)
                    signingProblem = nil
                    CartoucheImportedSigning.measure(via: "installer", error: nil)
                } catch {
                    signingProblem = error.localizedDescription
                    CartoucheImportedSigning.measure(via: "installer", error: error)
                }
                try? FileManager.default.removeItem(at: handoff)
                isImportingSigning = false
                finishSigningImport()
            }
            return
        }
        hasCertificate = CartoucheCertificate.handOff()
        checkCertificate()
        if CartouchePairing.takeDroppedFile() { pairingReport = nil }
        hasPairingFile = CartouchePairing.exists
        #if CARTOUCHE_GALLERY
        // The gallery has no SideStore keychain.
        appleID = GalleryState.setupDone || GalleryState.signInUnfinished ? "player@icloud.com" : nil
        #else
        appleID = CartoucheStoreKeychain.string("appleIDEmailAddress")
        #endif
    }

    /// Notes whether the step that registers this iPhone is left.
    func noteDeviceStep(left: Bool) {
        if deviceStepLeft != left { deviceStepLeft = left }
        if left {
            UserDefaults.standard.set(true, forKey: Self.deviceStepKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.deviceStepKey)
        }
    }

    #if CARTOUCHE_GALLERY
    /// That step left, for the gallery's screens, without keeping it.
    func showDeviceStepForGallery() {
        deviceStepLeft = true
    }
    #endif

    /// The player can drop the pairing file on Cartouche while it is open.
    func refreshPairingFile() {
        if CartouchePairing.takeDroppedFile() { pairingReport = nil }
        let exists = CartouchePairing.exists
        if exists != hasPairingFile { hasPairingFile = exists }
    }

    func importPairingFile(_ url: URL) {
        do {
            try CartouchePairing.importFile(at: url)
            pairingReport = nil
            CartoucheReports.note("Pairing file received")
        } catch {
            pairingFailed(error)
        }
        refresh()
    }

    /// The pairing file the player gave could not be taken, as ERROR says.
    func pairingFailed(_ error: Error) {
        pairingReport = CartoucheReports.make(.pairing, CartoucheText.setupPairingFailed, message: error.localizedDescription,
                                              error: error, step: "Taking the pairing file", stage: "pairingFile")
    }

    func importOpenedPairingFile(_ url: URL) {
        importPairingFile(url)
        openedPairingFile = true
    }

    // MARK: Whether the certificate works

    func importSigning(certificate: Data, password: String, profile: Data) async {
        guard CartoucheImportedSigning.isImportedInstall, !isImportingSigning else { return }
        isImportingSigning = true
        do {
            try await CartoucheImportedSigning.importMaterial(.init(certificate: certificate, password: password, profile: profile))
            signingProblem = nil
            CartoucheImportedSigning.measure(via: "setup", error: nil)
        } catch {
            signingProblem = error.localizedDescription
            CartoucheImportedSigning.measure(via: "setup", error: error)
        }
        isImportingSigning = false
        finishSigningImport()
    }

    private func finishSigningImport() {
        checked.removeAll()
        checking = nil
        certificateWorks = nil
        refresh()
    }

    /// Checks LiveContainer's certificate once per launch, and each time it
    /// changes.
    private func checkCertificate() {
        guard hasCertificate, let certificate = CartoucheCertificate.current else {
            certificateWorks = nil
            return
        }
        if let works = checked[certificate] {
            found(works, for: certificate)
            return
        }
        if certificateWorks != nil { certificateWorks = nil }
        guard checking != certificate else { return }
        checking = certificate
        Task {
            let works = await CartoucheCertificate.works()
            checked[certificate] = works
            if checking == certificate { checking = nil }
            if CartoucheCertificate.current == certificate { found(works, for: certificate) }
        }
    }

    /// A game LiveContainer signed did not pass iOS's check.
    func certificateRefusedAtStart() {
        guard let certificate = CartoucheCertificate.current else { return }
        checked[certificate] = false
        found(false, for: certificate)
    }

    private func found(_ works: Bool, for certificate: Data) {
        if certificateWorks != works { certificateWorks = works }
        // SideStore signs in again with the Apple ID it keeps, and takes the
        // certificate that signs Cartouche: the player only steps in should
        // Apple ask for a code, or the sign-in fail. Once per certificate;
        // until LocalDevVPN is connected, each time Cartouche comes back.
        if !works, !CartoucheImportedSigning.accountSigningDisabled, !replacing.contains(certificate) {
            if #available(iOS 17.0, *), CartoucheAccount.shared.signInAgain() {
                replacing.insert(certificate)
            }
        }
    }
}

/// Reads the setup again whenever Cartouche comes back to the front, and
/// looks for the pairing file every two seconds until it is there. While
/// this iPhone is left to register, looks every two seconds whether
/// LocalDevVPN has connected: Cartouche then takes that step by itself. A
/// sign-in that stopped before the certificate, in an earlier installation,
/// starts again when Cartouche comes to the front. In the last days of its
/// signature, Cartouche renews itself as it comes to the front, and once
/// the setup is found complete after the launch (CartoucheRenewals).
@available(iOS 17.0, *)
@MainActor
struct CartoucheSetupRefresh: ViewModifier {
    @ObservedObject var setup = CartoucheSetup.shared

    func body(content: Content) -> some View {
        content
            .onAppear {
                setup.refresh()
                CartoucheAccount.shared.resumeDeviceStep()
                CartoucheAccount.shared.resumeSignIn()
                CartoucheRenewals.shared.renewIfDue()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                setup.refresh()
                CartoucheAccount.shared.resumeDeviceStep()
                CartoucheAccount.shared.resumeSignIn()
                CartoucheRenewals.shared.renewIfDue()
            }
            // The certificate's check ends a few seconds after the launch.
            .onChange(of: setup.isComplete) { _, complete in
                if complete { CartoucheRenewals.shared.renewIfDue() }
            }
            // The pairing step ticks itself once the player has dropped the file.
            .task(id: setup.hasPairingFile) {
                while !setup.hasPairingFile && !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    setup.refreshPairingFile()
                }
            }
            .task(id: setup.needsDevice) {
                while setup.needsDevice && !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    CartoucheAccount.shared.resumeDeviceStep()
                }
            }
    }
}
