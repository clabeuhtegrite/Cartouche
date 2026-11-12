//
//  CartoucheRootView.swift
//  Cartouche
//
//  Cartouche's screens, in place of LiveContainer's tab bar
//  (app/patches/livecontainer/0006): the console, and the System page over
//  it, which the dock or the controller's Menu button opens. Cartouche
//  drives LiveContainer and the built-in SideStore without ever showing a
//  page of theirs (docs/decisions.md, 24). Cartouche puts no badge on its
//  icon: one left there is cleared each time it comes to the screen.
//

import SwiftUI
import UserNotifications

@available(iOS 17.0, *)
struct CartoucheRootView: View {
    @EnvironmentObject private var sharedModel: SharedModel

    var body: some View {
        CartoucheGamesView()
            .fullScreenCover(isPresented: showsSystem) {
                CartoucheSystemView()
                    .environmentObject(sharedModel)
            }
            .onAppear {
                CartoucheReports.noteStart()
                Self.clearBadge()
                CartoucheTelemetry.shared.start()
                // A Files picker open when Cartouche last ended.
                CartoucheImportPicker.noteLeftOpen()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Self.clearBadge()
            }
    }

    /// The built-in SideStore of an older Cartouche counted its updates on
    /// the icon, and nothing took the count away (app/patches/sidestore/0013).
    static func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
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
