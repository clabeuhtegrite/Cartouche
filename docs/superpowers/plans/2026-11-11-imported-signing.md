# Imported Signing Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Keep work in the existing Orca worktree.

**Goal:** Install Cartouche and sign its games using imported signing material without Apple ID authentication.

**Architecture:** Reuse apple-codesign-quick and isideload's installation transport, bypassing developer portal calls. Transfer the identity through Cartouche's Documents import path into its keychain, select an explicit signing source, and disable SideStore renewal/update installation while imported mode is active.

**Tech Stack:** Rust/Tauri/React installer; Swift/SwiftUI launcher; Python regression checks.

**Spec:** docs/superpowers/specs/2026-11-11-imported-signing-design.md (approved in conversation).

## Constraints and review focus

- Keep existing Apple ID signing available; imported mode must not call it.
- Validate keys, profile, device, expiration and app/extension eligibility before installing.
- Respect supplied entitlements; fail clearly for unsupported permissions.
- No remote signing or credential logging; temporary credentials must be private and cleaned.
- Preserve imported selection across refresh and restart; failed imports must preserve working material.
- Keep launcher and installer English/French strings complete.

## Tasks

- [x] Add failing Rust tests for imported profile eligibility, identifier expansion, certificate selection and invalid import handling. Implement local PKCS#12 import, entitlement validation and bundle signing in `installer/src-tauri/src/imported_signing.rs` using pinned existing transitive dependencies.
- [x] Wire `install_cartouche_operation` and installer signing choice to the imported path. Transfer signing material to Cartouche after installation; keep backend validation independent of UI guards. Build and test installer.
- [x] Add a testable launcher signing-source policy and certificate import/handoff. Expose import and switch controls in setup, adjust readiness, prevent account replacement and automatic renewal/update installation. Add English/French strings and regression coverage.
- [x] Document supported profiles and update behavior, run relevant app regression tests and installer checks, review the full diff, and report hardware verification limits.

## Execution notes

- Existing worktree branch: `feat-use-flarestore-certificates`; no push or commit requested.
- Pinned submodules are empty locally. Inspect downloaded pinned source in `/tmp` and apply patches there for validation without changing submodule revisions.
- `ccc` is unavailable; use `rg` for repository navigation rather than introducing unrelated indexing infrastructure.

- Ruling: omit all bundled extensions in basic imported installs, use a private engine sandbox, and require the complete game keychain group set — wildcard profiles can work without app groups; explicit profiles lacking keychain permissions fail before installation.
- Ruling: imported keychain material is consumed directly by native accessors; a transient in-memory candidate is used during a serialized iOS acceptance probe. No imported P12/password copies enter UserDefaults.
- Review: three important findings (credential preference copies, insufficient guest keychain permissions, concurrent probes) were fixed and rechecked by a fresh reviewer; no remaining material findings.
- Verification: 79 app regression checks using disposable copies of the exact pinned upstream sources; 14 Rust installer tests, including actual local bundle signing with generated PKCS#12/CMS data; installer TypeScript/Vite production build; Gallery simulator build; native LCSharedUtils iOS syntax check; actual Swift/Objective-C bridge and SideStoreSupport iOS typechecks; all nine engine patches applied cleanly.
- Limitation: no physical iPhone or actual FlareStore identity was supplied, so device installation and game signature acceptance remain unverified. The user guide records the hardware validation checklist.
- Full native app compilation was not run: the checkout's recursive submodules are empty. Standalone bootstrap syntax checking also needs the pinned `litehook` header; the patched keychain helper and SideStoreSupport bridge passed their iOS compiler checks.
