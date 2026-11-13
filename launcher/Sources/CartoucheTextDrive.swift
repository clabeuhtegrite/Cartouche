//
//  CartoucheTextDrive.swift
//  Cartouche
//
//  The words of the player's Google Drive as storage
//  (CartoucheStorageDrive.swift, CartoucheStorageDriveView.swift), in
//  Cartouche.xcstrings with the others (CartoucheText.swift).
//

import Foundation

extension CartoucheText {
    // MARK: Google Drive

    static var storageAddDrive: String { s("storage.drive.add", "Add Google Drive") }
    static var storageDriveTitle: String { s("storage.drive.title", "Google Drive") }
    static var storageDriveClient: String { s("storage.drive.client", "Your Google client") }
    static var storageDriveClientField: String { s("storage.drive.client.field", "Client ID") }
    static var storageDriveClientFooter: String { s("storage.drive.client.footer", "Cartouche has no Google key of its own: it reaches your Drive through an OAuth client of yours, made once, for free, in Google Cloud. Paste its ID, or all the text Google Cloud gives with it.") }
    static var storageDriveHowTo: String { s("storage.drive.howTo", "Make your client, step by step") }
    static var storageDriveAccount: String { s("storage.drive.account", "Google account") }
    static var storageDriveSignIn: String { s("storage.drive.signIn", "Sign in with Google") }
    static var storageDriveSignInAgain: String { s("storage.drive.signInAgain", "Sign in to Google again") }
    static var storageDriveAccountFooter: String { s("storage.drive.account.footer", "Google asks you to let your client see, edit and delete the files of your Drive: Cartouche installs your games from there and keeps your saves there, in My Drive alone. Your sign-in stays in this iPhone’s keychain.") }
    static var storageDriveBadClient: String { s("storage.drive.badClient", "This is not a client ID: Google Cloud shows it under your client, ending with .apps.googleusercontent.com.") }
    static var storageDriveClientRefused: String { s("storage.drive.clientRefused", "Google does not know this client, or it is not of the iOS type: check its ID in Google Cloud, or make the client again.") }
    static var storageDriveSignInNeeded: String { s("storage.drive.signInNeeded", "Sign in to Google in System › Storage: Cartouche reaches your Drive only with your own account.") }
    static var storageDriveOff: String { s("storage.drive.off", "The Google Drive API is off in your Google Cloud project: turn it on, wait a minute, then sign in again.") }
    static var storageDriveTurnOn: String { s("storage.drive.turnOn", "Turn on the Drive API") }
    static var storageDriveScope: String { s("storage.drive.scope", "Google did not let Cartouche reach your Drive: sign in again, and allow your client to see, edit and delete your Drive’s files.") }
    static var storageDriveNoRefreshToken: String { s("storage.drive.noRefreshToken", "Google gave no lasting sign-in: sign in again.") }
    static var storageDriveRefusedOnPage: String { s("storage.drive.refusedOnPage", "You did not allow your client on Google’s page.") }
    static func storageDriveSignInFailed(_ reason: String) -> String { f("storage.drive.signInFailed", "Google did not sign you in: %@", reason) }
    static func storageDrivePageFailed(_ reason: String) -> String { f("storage.drive.pageFailed", "Google’s sign-in page did not open: %@", reason) }
    static var storageDriveFull: String { s("storage.drive.full", "Your Google Drive is full.") }
    static var storageDriveReadOnly: String { s("storage.drive.readOnly", "Your Google account can only read here.") }
    static var storageDriveNotThere: String { s("storage.drive.notThere", "This file or folder is no longer on your Google Drive.") }
    static var storageDriveBadAnswer: String { s("storage.drive.badAnswer", "Google Drive gave an answer Cartouche does not understand.") }
    static func storageDriveFailed(_ reason: String) -> String { f("storage.drive.failed", "Google Drive refused: %@", reason) }
    static func storageDriveSignedOut(_ name: String) -> String { f("storage.drive.signedOut", "Google ended Cartouche’s sign-in to %@, as it does after 7 days for a project in testing: sign in to Google again in System › Storage. Meanwhile your games installed play, and your saves wait.", name) }
    /// A few words, beside the Drive's name.
    static func storageDriveSignedOutShort(_ name: String) -> String { f("storage.drive.signedOut.short", "%@: sign in again", name) }
    /// Under a game of the games folder, on a Drive whose sign-in ended.
    static func statusStoredSignedOut(_ server: String) -> String { f("status.stored.signedOut", "Sign in to %@ again in System › Storage to install this game.", server) }
    static func statusUpdateSignedOut(_ server: String) -> String { f("status.update.signedOut", "Sign in to %@ again in System › Storage to update this game.", server) }

    // MARK: Making the client

    static var storageDriveGuideTitle: String { s("storage.drive.guide.title", "Your Google client") }
    static var storageDriveGuideIntro: String { s("storage.drive.guide.intro", "Once, for free, in Google Cloud, with the Google account of your Drive: on this iPhone, or on a computer, where it is easier. Each button opens its step’s page.") }
    static var storageDriveStepProject: String { s("storage.drive.step.project", "Create a project") }
    static var storageDriveStepProjectDetail: String { s("storage.drive.step.project.detail", "Name it Cartouche, then Create.") }
    static var storageDriveStepAPI: String { s("storage.drive.step.api", "Turn on the Google Drive API") }
    static var storageDriveStepAPIDetail: String { s("storage.drive.step.api.detail", "With your project chosen at the top of the page, Enable.") }
    static var storageDriveStepBranding: String { s("storage.drive.step.branding", "Set up Google’s sign-in page") }
    static var storageDriveStepBrandingDetail: String { s("storage.drive.step.branding.detail", "Get started: Cartouche as the app’s name, your address, External as the audience, your address again, then Create.") }
    static var storageDriveStepTester: String { s("storage.drive.step.tester", "Add yourself as a test user") }
    static var storageDriveStepTesterDetail: String { s("storage.drive.step.tester.detail", "Under Test users, Add users: the address of your Google account, then Save.") }
    static var storageDriveStepClient: String { s("storage.drive.step.client", "Create the client") }
    static var storageDriveStepClientDetail: String { s("storage.drive.step.client.detail", "iOS as the application type, Cartouche as its name and this bundle ID, then Create. Copy the client ID Google shows.") }
    static var storageDriveStepSignIn: String { s("storage.drive.step.signIn", "Paste it in Cartouche and sign in") }
    static var storageDriveStepSignInDetail: String { s("storage.drive.step.signIn.detail", "Google says it has not verified the app: it is yours, choose Continue, then allow access to your Drive’s files.") }
    static var storageDriveBundleID: String { s("storage.drive.bundleID", "Bundle ID") }
    static var storageDriveCopy: String { s("storage.drive.copy", "Copy") }
    static var storageDriveCopied: String { s("storage.drive.copied", "Copied") }
    static var storageDriveOpenStep: String { s("storage.drive.openStep", "Open in Google Cloud") }
    static var storageDriveWeekly: String { s("storage.drive.weekly", "While your project is in testing, Google ends the sign-in after 7 days: Cartouche then asks you to sign in again, in a few taps, and your saves wait meanwhile. To sign in once for good, publish the app under Audience, when Google offers it.") }
}
