//
//  CartoucheStorageMacView.swift
//  Cartouche
//
//  The player's Mac on the Storage page (CartoucheStorageView): the Macs
//  nearby whose Cartouche Builder shares with Cartouche, the six digits to
//  compare with the Mac's while pairing, and, for a new Mac, whether its
//  Games and Saves folders become the games folder and the saves folder.
//  The bridge itself is in CartoucheStorageMac.swift.
//

import Combine
import Network
import SwiftUI
import UIKit

/// Pairing this iPhone with a Mac nearby: one at a time, ended when the
/// form goes.
@MainActor
final class CartoucheMacPairing: ObservableObject {
    /// The Mac being paired with.
    @Published private(set) var mac: CartoucheNearbyMac?
    /// The six digits, once both sides have them.
    @Published private(set) var code: String?
    @Published var problem: CartoucheReport?
    private var task: Task<Void, Never>?
    /// The pairing under way: one cancelled ends later, and changes nothing.
    private var attempt = UUID()

    var isPairing: Bool { mac != nil }

    #if CARTOUCHE_GALLERY
    /// The pairing the launcher's gallery (launcher/Gallery) shows: the Mac
    /// being paired with, and the six digits both screens show.
    static var gallery: (mac: CartoucheNearbyMac, code: String)?

    init() {
        if let gallery = Self.gallery {
            mac = gallery.mac
            code = gallery.code
        }
    }
    #endif

    /// Pairs SERVER with MAC, then hands DONE the server to save and its
    /// paired key, base64.
    func start(_ server: CartoucheStorageServer, with mac: CartoucheNearbyMac,
               done: @escaping @MainActor (CartoucheStorageServer, String) async -> Void) {
        task?.cancel()
        let attempt = UUID()
        self.attempt = attempt
        self.mac = mac
        code = nil
        problem = nil
        let deviceName = UIDevice.current.name
        task = Task {
            var paired: (server: CartoucheStorageServer, secret: String)?
            var failure: Error?
            do {
                paired = try await CartoucheMacStorage.pair(server, at: mac.endpoint, name: mac.name, deviceName: deviceName) { digits in
                    Task { @MainActor in
                        if self.attempt == attempt { self.code = digits }
                    }
                }
            } catch {
                failure = error
            }
            guard self.attempt == attempt, !Task.isCancelled else { return }
            if let paired {
                await done(paired.server, paired.secret)
            } else if let failure, !(failure is CancellationError) {
                var named = server
                named.kind = .mac
                if named.name.trimmingCharacters(in: .whitespaces).isEmpty { named.name = mac.name }
                problem = CartoucheReports.connectionFailed(to: named, error: failure)
            }
            self.mac = nil
            code = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        attempt = UUID()
        mac = nil
        code = nil
    }
}

// MARK: The form

@available(iOS 17.0, *)
struct CartoucheStorageMacForm: View {
    @State private var server: CartoucheStorageServer
    @StateObject private var nearby = CartoucheMacBrowser()
    @StateObject private var pairing = CartoucheMacPairing()
    /// For a new Mac: whether its folders become the games folder and the
    /// saves folder, as they do when there are none yet.
    @State private var useGames: Bool
    @State private var useSaves: Bool
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool
    /// The Macs this iPhone is paired with already, as other places.
    private let added: Set<String>

    init(server: CartoucheStorageServer) {
        let settings = CartoucheStorageSettings.shared
        _server = State(initialValue: server)
        isNew = settings.server(server.id) == nil
        _useGames = State(initialValue: settings.place(.games) == nil)
        _useSaves = State(initialValue: settings.place(.saves) == nil)
        added = Set(settings.servers.filter { $0.kind == .mac && $0.id != server.id }.compactMap(\.macID))
    }

    var body: some View {
        Form {
            nearbySection
            if let code = pairing.code {
                Section {
                    Text(verbatim: CartoucheBridge.spaced(code))
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .accessibilityLabel(code.map(String.init).joined(separator: " "))
                    Text(CartoucheText.storageMacCheckCode)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(CartoucheText.storageMacPairing(pairing.mac?.name ?? server.name))
                }
            } else if let mac = pairing.mac {
                Section {
                    HStack {
                        ProgressView()
                        Text(CartoucheText.storageMacReaching(mac.name))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let problem = pairing.problem {
                Section {
                    Text(problem.message)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                    CartoucheReportButton(report: problem)
                }
            }
            if isNew {
                Section {
                    Toggle(CartoucheText.storageMacUseGames, isOn: $useGames)
                    Toggle(CartoucheText.storageMacUseSaves, isOn: $useSaves)
                } footer: {
                    Text(CartoucheText.storageMacUseFooter)
                }
            } else {
                Section {
                    TextField(CartoucheText.storageName, text: $server.name)
                    if !server.host.isEmpty {
                        LabeledContent(CartoucheText.storageMacLastAddress, value: server.host)
                    }
                } header: {
                    Text(CartoucheText.storageNameTitle)
                }
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(isNew ? CartoucheText.storageMacTitle : server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(CartoucheText.cancel) {
                    pairing.cancel()
                    dismiss()
                }
            }
            if !isNew {
                ToolbarItem(placement: .confirmationAction) {
                    Button(CartoucheText.storageSave) { saveName() }
                        .disabled(pairing.isPairing || server.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { nearby.start() }
        .onDisappear {
            nearby.stop()
            pairing.cancel()
        }
    }

    private var nearbySection: some View {
        Section {
            // No search to wait for while iOS refuses the local network.
            if nearby.found.isEmpty && !nearby.refused {
                HStack {
                    ProgressView()
                    Text(CartoucheText.storageMacLooking)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(nearby.found) { mac in
                let isAdded = mac.macID.map { added.contains($0) } ?? false
                Button {
                    pairing.start(server, with: mac) { made, secret in
                        await paired(made, secret: secret)
                    }
                } label: {
                    LabeledContent {
                        if pairing.mac?.id == mac.id {
                            ProgressView()
                        } else if mac.macID != nil, mac.macID == server.macID {
                            Text(CartoucheText.storageMacPaired)
                        } else if isAdded {
                            Text(CartoucheText.storageMacAdded)
                        }
                    } label: {
                        Label(mac.name, systemImage: "laptopcomputer")
                    }
                }
                .tint(.primary)
                .disabled(pairing.isPairing || isAdded)
            }
            if nearby.refused {
                Text(CartoucheText.storageMacLocalNetwork)
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
            }
        } header: {
            Text(CartoucheText.storageMacNearby)
        } footer: {
            Text(isNew ? CartoucheText.storageMacHow : CartoucheText.storageMacPairAgain)
        }
    }

    /// Keeps the Mac now paired, and, for a new one, takes its folders for
    /// the games and the saves the player chose.
    private func paired(_ made: CartoucheStorageServer, secret: String) async {
        let settings = CartoucheStorageSettings.shared
        settings.save(made, secret: secret)
        if isNew, useGames || useSaves, let remote = try? await CartoucheStorage.connect(made, settings: settings) {
            // The folders the Mac shares: Saves only once the player chose
            // where they go in Cartouche Builder.
            let shared = Set(((try? await remote.list("")) ?? []).filter(\.isFolder).map(\.name))
            for (role, folder, wanted) in [(CartoucheStorageRole.games, CartoucheBridge.gamesFolder, useGames),
                                           (CartoucheStorageRole.saves, CartoucheBridge.savesFolder, useSaves)]
                where wanted && shared.contains(folder) {
                settings.setPlace(CartoucheStoragePlace(server: made.id, path: folder), for: role)
                await settings.checkAccess(remote, server: made.id, path: folder)
            }
            await remote.disconnect()
        }
        CartoucheStoredGames.shared.refresh()
        dismiss()
    }

    private func saveName() {
        server.name = server.name.trimmingCharacters(in: .whitespaces)
        CartoucheStorageSettings.shared.save(server, secret: nil)
        dismiss()
    }
}
