# Imported signing certificates

## Intent

Support a FlareStore signing certificate for both installing Cartouche from a computer and signing games inside Cartouche. Keep the existing Apple ID signing option available. The import format is a PKCS#12 file, its password, and an Apple provisioning profile; the implementation must also work with compatible certificates from other providers.

## Installer

Add a signing choice beside the existing Apple ID step: Apple ID or imported certificate. The imported option chooses a `.p12`, a `.mobileprovision`, and a password. It does not require Apple ID authentication. Retain device selection, Cartouche-only IPA validation, release hash verification, progress reporting, and the existing installation transport.

Validate the private key and certificate, certificate/profile match, expiration dates, target device eligibility, application identifiers for the app and retained extensions, and permissions needed by Cartouche before installation. A profile grants permissions; importing a certificate cannot add permissions to it. Refuse unsupported profiles with a specific explanation instead of silently producing an unusable app. Do not request Apple developer portal changes or revoke account certificates in this mode.

Sign locally. Adapt the existing signing library if it supports a supplied identity/profile; otherwise add a local signing backend with pinned dependencies after inspecting its API. Never upload signing credentials or IPAs to a provider. Apply only profile-authorized entitlements, preserving the identifiers and groups required for supported Cartouche features. Account explicitly for extension profiles; never assume a single explicit app profile covers every extension. Embed the supplied profile and make the identity available to Cartouche for game signing through a dedicated import handoff, independent of SideStore's development-certificate discovery.

Keep passwords out of logs and persisted frontend settings. Use private temporary storage for any necessary signing material and clean it on success and failure. Durable secrets belong in the platform keychain. On a platform without keychain support, use the identity only for the current install unless a separate, explicit persistence choice is provided.

## Cartouche

Add imported-certificate management to setup: import or replace a `.p12` with its password and provisioning profile, show validation errors and status, and switch back to Apple ID signing. Store the imported identity separately from SideStore's account identity. Keep certificate source as explicit state so foreground refresh and account sign-in cannot overwrite the imported selection.

An installer-provided identity enters the same validation and selection path as a manual import. Require compatible signing identity/profile and installed-host signing permissions; replacing only a game certificate must not imply the installed host has acquired new entitlements. Validate that iOS accepts signed code using Cartouche's existing JIT-less probe. Preserve an existing working selection when an import fails. Invalidate cached certificate checks after a successful change.

When imported signing is selected, a rejected certificate requests replacement of that imported certificate rather than automatically signing in with an Apple ID. Separate game readiness from the SideStore renewal requirements. Hide Apple ID, pairing and VPN requirements from imported-mode game setup unless another selected feature needs them. Keep English and French strings consistent.

## Renewal and updates

SideStore currently renews and updates through an Apple ID. Imported mode must never silently re-sign Cartouche with that identity. For the first implementation, keep release checking and direct users to install the update with the computer installer using their imported certificate. Disable SideStore renewal and in-app installation in imported mode, and explain that choice in setup and update UI. Switching back to Apple ID mode restores the existing renewal path when its requirements are met.

## Validation

Use behavioral tests for invalid passwords, missing private keys, expired identities/profiles, mismatched certificate and profile, unsupported device/app/extension identifiers, and missing required permissions. Test certificate-source selection across refresh, failed import, successful replacement, restart, and switching back to the account. Test that imported mode cannot invoke Apple ID signing or renewal accidentally. Run installer build/tests and launcher localization and relevant regression checks.

An iPhone validation pass must install Cartouche with a compatible imported identity, open it, import and launch a game, foreground and restart it, replace the certificate, and check the update flow. Local tests alone cannot establish iOS signature acceptance. Do not claim arbitrary FlareStore profiles are supported without verifying their permissions.

## Implementation choices

The user approved both installer and in-app game signing without Apple ID sign-in, with computer-based updates, in the conversation on 2026-11-11.

Implementation decisions: basic imported installations omit app extensions and run games in Cartouche's place, using a private sandbox directory instead of app groups. Profiles must authorize the app identifier and the engine's complete set of 128 team-based game keychain groups. Insufficient profiles fail with an explanation. Imported credentials are persisted only in the device keychain; native engine accessors cache them in memory and use an in-memory candidate for validation. Certificate probes run serially through native cleanup.
