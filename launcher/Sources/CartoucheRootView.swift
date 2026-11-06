//
//  CartoucheRootView.swift
//  Cartouche
//
//  Cartouche's screens, in place of LiveContainer's tab bar
//  (app/patches/livecontainer/0006): the console, and the System page over
//  it, which the dock or the controller's Menu button opens. Cartouche
//  drives LiveContainer and the built-in SideStore without ever showing a
//  page of theirs (docs/decisions.md, 24).
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheRootView: View {
    @EnvironmentObject private var sharedModel: SharedModel

    var body: some View {
        CartoucheGamesView()
            .fullScreenCover(isPresented: showsSystem) {
                CartoucheSystemView()
                    .environmentObject(sharedModel)
            }
    }

    /// The System page is on screen while it is the selected tab; closing it
    /// goes back to the console.
    private var showsSystem: Binding<Bool> {
        Binding(
            get: { sharedModel.selectedTab == .system },
            set: { shown in
                if !shown && sharedModel.selectedTab == .system {
                    sharedModel.selectedTab = .games
                }
            })
    }
}

/// What an iOS older than 17 shows in place of Cartouche's screens, which
/// need it.
struct CartoucheNeedsNewerIOSView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text(CartoucheText.needsNewerIOS)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
