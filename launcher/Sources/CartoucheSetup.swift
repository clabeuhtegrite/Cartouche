//
//  CartoucheSetup.swift
//  Cartouche
//
//  What Cartouche needs before it plays games and renews itself, and what it
//  does on its own:
//
//  - The certificate. iloader puts its signing certificate inside the built-in
//    SideStore when it installs Cartouche (app/scripts/brand.py says why), and
//    SideStore takes it into its keychain once the player signs in with their
//    Apple ID. Cartouche then hands it to LiveContainer, which signs each game
//    with it: no button, no file, every time Cartouche comes to the front.
//  - The pairing file, which only a computer can make: SideStore needs it to
//    install and renew apps. iloader exports it; Cartouche puts it where the
//    built-in SideStore reads it, as iloader does for a LiveContainer+SideStore.
//  - LocalDevVPN, from the App Store, through which SideStore reaches the
//    iPhone's own services when it renews Cartouche.
//

import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

/// The built-in SideStore's keychain items. SideStore names its keychain
/// service after the bundle identifier SideStoreHooks gives it, Cartouche's
/// own without the team suffix that signing adds, which app/scripts/package.sh
/// writes into the Info.plist; the items sit in the keychain group iloader
/// gives Cartouche.
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
}

enum CartouchePairing {
    /// The built-in SideStore's Documents folder: LiveContainer gives it the
    /// SideStore folder of its own Documents as its home.
    static var storeDocuments: URL {
        LCPath.docPath.appendingPathComponent("SideStore/Documents", isDirectory: true)
    }

    /// The names SideStore reads a pairing file under (PairingFileManager).
    static let fileNames = ["PairingFile_RemoteRP.plist", "PairingFile_Lockdown.plist", "ALTPairingFile.mobiledevicepairing"]
    /// The one iloader writes for a LiveContainer+SideStore. SideStore works
    /// out which kind of pairing file it is when it reads it.
    static let importName = "ALTPairingFile.mobiledevicepairing"

    static var exists: Bool {
        fileNames.contains { FileManager.default.fileExists(atPath: storeDocuments.appendingPathComponent($0).path) }
    }

    static var contentTypes: [UTType] {
        var types = ["mobiledevicepairing", "mobiledevicepair", "plist"].compactMap { UTType(filenameExtension: $0) }
        types.append(contentsOf: [.propertyList, .xml, .data])
        return types
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
    @Published private(set) var hasPairingFile = false
    @Published private(set) var appleID: String?

    /// Games start once LiveContainer has the certificate.
    var canPlay: Bool { hasCertificate }
    /// Cartouche also renews itself once SideStore has the pairing file.
    var isComplete: Bool { hasCertificate && hasPairingFile }

    private init() {
        refresh()
    }

    /// Reads everything again, after handing SideStore's certificate to
    /// LiveContainer: call it each time Cartouche comes to the front, since
    /// the player signs in from SideStore.
    func refresh() {
        hasCertificate = CartoucheCertificate.handOff()
        hasPairingFile = CartouchePairing.exists
        appleID = CartoucheStoreKeychain.string("appleIDEmailAddress")
    }

    func importPairingFile(_ url: URL) throws {
        try CartouchePairing.importFile(at: url)
        refresh()
    }
}

/// Reads the setup again whenever Cartouche comes back to the front.
@available(iOS 17.0, *)
@MainActor
struct CartoucheSetupRefresh: ViewModifier {
    @ObservedObject var setup = CartoucheSetup.shared

    func body(content: Content) -> some View {
        content
            .onAppear { setup.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                setup.refresh()
            }
    }
}
