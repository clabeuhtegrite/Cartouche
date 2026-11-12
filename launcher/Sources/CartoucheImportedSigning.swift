import Foundation
import Security

enum CartoucheImportedSigning {
    static let handoffName = "CartoucheSigning.plist"
    private static let account = "Cartouche.importedSigning.material"

    static var isImportedInstall: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CartoucheImportedSigning") as? Bool == true
    }
    static var isSelected: Bool {
        isImportedInstall
    }
    static var accountSigningDisabled: Bool { isImportedInstall }
    static var material: CartoucheSigningMaterial? {
        CartoucheStoreKeychain.data(account).flatMap {
            try? PropertyListDecoder().decode(CartoucheSigningMaterial.self, from: $0)
        }
    }

    /// Update atomically so a keychain failure preserves the previous import.
    private static func save(_ data: Data) -> Bool {
        guard let service = CartoucheStoreKeychain.service else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    @MainActor
    static func importMaterial(_ material: CartoucheSigningMaterial) async throws {
        guard isImportedInstall else { throw ImportError(message: CartoucheText.signingReinstall, kind: "reinstall") }
        if #available(iOS 17.0, *) {
            guard CartoucheAccount.shared.phase == nil, CartoucheUpdates.shared.phase == nil else {
                throw ImportError(message: CartoucheText.signingWait, kind: "busy")
            }
        }
        guard let team = LCUtils.getCertTeamId(withKeyData: material.certificate, password: material.password) else {
            throw ImportError(message: CartoucheText.signingInvalidKey, kind: "invalidKey")
        }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: material.password] as CFDictionary
        guard SecPKCS12Import(material.certificate as CFData, options, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String] else {
            throw ImportError(message: CartoucheText.signingInvalidKey, kind: "invalidKey")
        }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw ImportError(message: CartoucheText.signingInvalidKey, kind: "invalidKey")
        }
        let hostProfile = try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision"))
        #if CARTOUCHE_GALLERY
        let hostTeam = team
        #else
        let hostTeam = LCSharedUtils.teamIdentifier() ?? ""
        #endif
        do {
            try material.validate(certificateDER: SecCertificateCopyData(certificate) as Data,
                                  team: team, hostTeam: hostTeam, hostProfile: hostProfile)
        } catch CartoucheSigningMaterial.Problem.reinstall {
            throw ImportError(message: CartoucheText.signingReinstall, kind: "reinstall")
        } catch {
            throw ImportError(message: CartoucheText.signingInvalidProfile, kind: "invalidProfile")
        }
        guard await CartoucheCertificate.works(candidate: material) else {
            throw ImportError(message: CartoucheText.signingRefused, kind: "refused")
        }
        guard save(try PropertyListEncoder().encode(material)) else {
            throw ImportError(message: CartoucheText.signInKeychainFailed, kind: "keychain")
        }
        LCSharedUtils.setCartoucheSigningCandidate(nil)
        // Only a timestamp is persisted in engine preferences. Credentials
        // are read directly from the keychain by the patched accessors.
        LCUtils.appGroupUserDefault.set(Date(), forKey: "LCCertificateUpdateDate")
    }

    struct ImportError: LocalizedError {
        let message: String
        /// What went wrong, as a name for the telemetry: never the
        /// certificate, its password, its team or its profile.
        var kind = "other"
        var errorDescription: String? { message }
    }

    /// Says how an import of a certificate went: VIA, `installer` for the
    /// one the Cartouche Installer handed over, `setup` for one the player
    /// chose in Setup; and its outcome, `imported` or why not.
    @MainActor
    static func measure(via: String, error: Error?) {
        let outcome = error.map { ($0 as? ImportError)?.kind ?? "other" } ?? "imported"
        CartoucheTelemetry.shared.event("signing.imported", fields: ["via": .text(via), "outcome": .text(outcome)])
    }
}
