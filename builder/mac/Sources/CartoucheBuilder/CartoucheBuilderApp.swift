//
//  CartoucheBuilderApp.swift
//  Cartouche Builder
//
//  The Mac app: one window (the library, the builds, the storage, the
//  iPhone bridge and the Mac's tools), its settings, and an item in the
//  menu bar that keeps it at hand when the window is closed. Started with
//  --gallery FOLDER, it saves pictures of its screens with sample games
//  instead (Gallery.swift), for CI; with --background, as after an update
//  it installed by itself, it opens in the menu bar only.
//

import AppKit
import BuilderKit
import SwiftUI
import UserNotifications

@main
enum Main {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--gallery"), index + 1 < arguments.count {
            Gallery.run(into: URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        CartoucheBuilderApp.main()
    }
}

struct CartoucheBuilderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @AppStorage(AppSettings.menuBarKey) private var menuBar = true

    var body: some Scene {
        Window("Cartouche Builder", id: AppModel.mainWindow) {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.setup)
                .environmentObject(model.bridge)
                .environmentObject(model.covers)
                .environmentObject(model.updater)
                .environmentObject(model.telemetry)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1220, height: 780)
        .defaultLaunchBehavior(AppModel.launchedQuietly ? .suppressed : .automatic)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.setup)
                .environmentObject(model.bridge)
                .environmentObject(model.updater)
                .environmentObject(model.telemetry)
        }

        MenuBarExtra(isInserted: $menuBar) {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.covers)
                .environmentObject(model.updater)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            await AppModel.shared.start()
        }
    }

    /// With the item in the menu bar, the app stays when its window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.menuBar
    }

    /// An update downloaded goes in place as the app quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let updater = AppModel.shared.updater
        guard updater.installsAtQuit else { return .terminateNow }
        Task { @MainActor in
            await updater.install(relaunch: false)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let model = AppModel.shared
        if let section = info["section"] as? String, let found = AppSection(rawValue: section) { model.section = found }
        if let game = info["game"] as? String { model.selection = game }
        model.showMainWindow()
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(tr("Check nxnative", "Vérifier nxnative")) {
                Task { await model.refreshLibrary(update: true) }
            }
            .keyboardShortcut("r")
            .disabled(model.engine == nil || model.checking)
            Button(tr("Build what is due", "Construire ce qui est à reconstruire")) {
                model.build()
            }
            .keyboardShortcut("b")
            .disabled(!model.canBuild || (model.library?.due.isEmpty ?? true))
            Button(tr("Stop the builds", "Arrêter les constructions")) {
                model.stop()
            }
            .keyboardShortcut(".")
            .disabled(!model.isBuilding)
        }
        CommandGroup(replacing: .help) {
            Link(tr("Cartouche Builder’s guide", "Guide de Cartouche Builder"), destination: AppModel.guide)
            Link(tr("nxnative on GitHub", "nxnative sur GitHub"), destination: URL(string: "https://github.com/seedds/nxnative")!)
        }
    }
}
