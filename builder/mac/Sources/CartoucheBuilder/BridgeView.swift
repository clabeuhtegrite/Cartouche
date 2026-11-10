//
//  BridgeView.swift
//  Cartouche Builder
//
//  The bridge to Cartouche on the iPhone: on, this Mac is a storage place
//  Cartouche can add, its games folder (on the Mac or the NAS) and a saves
//  folder. An iPhone pairs once, with a code shown on both screens.
//

import BuilderKit
import CartoucheCore
import SwiftUI

struct BridgeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var bridge: BridgeController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "iPhone", subtitle: tr("Cartouche reads its games from this Mac", "Cartouche lit ses jeux depuis ce Mac"))
                switchCard
                if bridge.enabled {
                    howTo
                    folders
                    devices
                }
            }
            .padding(28)
        }
    }

    private var switchCard: some View {
        Card(padding: 20) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Theme.gradient)
                        .frame(width: 52, height: 52)
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Share with Cartouche on the iPhone", "Partager avec Cartouche sur l’iPhone"))
                        .font(.headline)
                    Text(stateText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { bridge.enabled }, set: { bridge.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.large)
            }
        }
    }

    private var stateText: String {
        guard bridge.enabled else {
            return tr("Off. On, the iPhone finds this Mac on your Wi-Fi and installs games from it, encrypted, once paired.",
                      "Désactivé. Activé, l’iPhone trouve ce Mac sur votre Wi-Fi et y installe ses jeux, chiffrés, une fois associé.")
        }
        switch bridge.state {
        case .stopped, .starting: return tr("Starting…", "Démarrage…")
        case .running:
            return tr("Visible on your network as “\(BridgeController.macName)”.", "Visible sur votre réseau sous « \(BridgeController.macName) ».")
                + (bridge.connected.isEmpty ? "" : tr(" An iPhone is connected: the Mac stays awake.", " Un iPhone est connecté : le Mac reste éveillé."))
        case let .failed(error):
            return tr("Could not start: ", "Démarrage impossible : ") + error
        }
    }

    private var howTo: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("On the iPhone", "Sur l’iPhone"))
                    .font(.headline)
                Step(number: 1, text: tr("Open Cartouche, then System › Storage › Add your Mac.", "Ouvrez Cartouche, puis Système › Stockage › Ajouter votre Mac."))
                Step(number: 2, text: tr("Choose “\(BridgeController.macName)” under Macs nearby.", "Choisissez « \(BridgeController.macName) » sous Macs à proximité."))
                Step(number: 3, text: tr("A code shows on both screens: allow the iPhone here if they are the same.",
                                         "Un code s’affiche sur les deux écrans : autorisez l’iPhone ici s’ils sont identiques."))
            }
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("What the iPhone sees", "Ce que voit l’iPhone").uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Card(padding: 6) {
                VStack(spacing: 0) {
                    FolderRow(symbol: "gamecontroller", title: tr("Games", "Jeux"),
                              path: bridge.games?.path ?? tr("Choose a games folder in the settings", "Choisissez un dossier des jeux dans les réglages"),
                              note: model.library?.folders?.games?.isShare == true ? tr("On your NAS, through this Mac", "Sur votre NAS, à travers ce Mac") : nil) {
                        EmptyView()
                    }
                    Divider().padding(.leading, 48)
                    FolderRow(symbol: "externaldrive.badge.icloud", title: tr("Saves", "Sauvegardes"), path: bridge.saves.path,
                              note: bridge.savesIsDefault ? tr("In Cartouche Builder’s folder", "Dans le dossier de Cartouche Builder") : nil) {
                        Button(tr("Change…", "Changer…")) {
                            if let url = FolderPicker.choose(title: tr("Where the iPhone’s saves go", "Où vont les sauvegardes de l’iPhone"), directory: bridge.saves) {
                                bridge.setSaves(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Paired iPhones", "iPhone associés").uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Card(padding: 6) {
                if bridge.devices.isEmpty {
                    Text(tr("None yet.", "Aucun pour l’instant."))
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(bridge.devices.enumerated()), id: \.element.id) { index, device in
                            if index > 0 { Divider().padding(.leading, 48) }
                            HStack(spacing: 14) {
                                Image(systemName: "iphone")
                                    .font(.title3)
                                    .frame(width: 24)
                                    .foregroundStyle(bridge.connected.contains(device.id) ? Color.green : Theme.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.callout.weight(.medium))
                                    Text(bridge.connected.contains(device.id)
                                         ? tr("Connected now", "Connecté maintenant")
                                         : tr("Paired ", "Associé ") + Format.relative(device.paired) + (device.seen.map { tr(", seen ", ", vu ") + Format.relative($0) } ?? ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(tr("Remove", "Retirer"), role: .destructive) { bridge.forget(device) }
                                    .controlSize(.small)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }
}

struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.indigo))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FolderRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let path: String
    let note: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.indigo)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
