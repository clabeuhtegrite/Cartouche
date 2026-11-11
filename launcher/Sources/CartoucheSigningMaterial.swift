import Foundation

/// The installer handoff and the keychain entry share this format. Keep
/// credential handling out of logging and reporting code.
struct CartoucheSigningMaterial: Codable {
    let certificate: Data
    let password: String
    let profile: Data

    enum Problem: Error { case invalidProfile, expired, mismatch, reinstall }

    static func profileContents(_ data: Data) throws -> [String: Any] {
        // Apple profiles wrap their XML property list in a CMS envelope.
        guard let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let values = try PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
        else { throw Problem.invalidProfile }
        return values
    }

    func validate(certificateDER: Data, team: String, hostTeam: String, hostProfile: Data) throws {
        let values = try Self.profileContents(profile)
        guard let expires = values["ExpirationDate"] as? Date else { throw Problem.invalidProfile }
        guard expires > Date() else { throw Problem.expired }
        guard (values["TeamIdentifier"] as? [String])?.contains(team) == true,
              (values["DeveloperCertificates"] as? [Data])?.contains(certificateDER) == true
        else { throw Problem.mismatch }
        // Importing a key cannot give an installed app another team's
        // permissions. Its embedded profile must already allow this signer.
        let host = try Self.profileContents(hostProfile)
        guard hostTeam == team,
              (host["DeveloperCertificates"] as? [Data])?.contains(certificateDER) == true
        else { throw Problem.reinstall }
    }
}
