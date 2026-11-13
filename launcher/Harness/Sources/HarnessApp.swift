//
//  HarnessApp.swift
//  CartoucheHarness
//
//  The harness's app: the launcher's code (launcher/Sources) on top of the
//  harness's LiveContainer (HarnessLiveContainer.swift), in the iOS
//  Simulator, for its tests (launcher/Harness/Tests), which run in it. It
//  shows a plain window of its own, the console's, which a game behind the
//  console covers with its own (CartoucheGameHost).
//

import SwiftUI

@main
struct HarnessApp: App {
    init() {
        HarnessLC.start()
    }

    var body: some Scene {
        WindowGroup {
            HarnessConsole()
        }
    }
}

/// The console's window: what a test sees under a game behind the console.
struct HarnessConsole: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Cartouche harness")
                .font(.title2.bold())
            Text("launcher/Harness")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("harness.console")
    }
}
