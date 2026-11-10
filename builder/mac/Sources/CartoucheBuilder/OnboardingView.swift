//
//  OnboardingView.swift
//  Cartouche Builder
//
//  The first start, in four steps: what the app does, this Mac's tools
//  installed, the player's folders chosen, and the iPhone bridge.
//

import BuilderKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var setup: MacSetup
    @EnvironmentObject private var bridge: BridgeController
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: tools
                case 2: folders
                default: iphone
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(32)
            Divider()
            HStack {
                ForEach(0..<4) { index in
                    Circle()
                        .fill(index == step ? Theme.indigo : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
                Spacer()
                if step > 0 {
                    Button(tr("Back", "Retour")) { withAnimation { step -= 1 } }
                }
                if step < 3 {
                    Button(step == 0 ? tr("Start", "Commencer") : tr("Continue", "Continuer")) { withAnimation { step += 1 } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(tr("Done", "Terminer")) { model.showOnboarding = false }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 680, height: 600)
        .interactiveDismissDisabled(model.needsOnboarding && step < 3)
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            AppIconView()
                .frame(width: 120, height: 120)
                .padding(.top, 20)
            Text(tr("Welcome to Cartouche Builder", "Bienvenue dans Cartouche Builder"))
                .font(.largeTitle.weight(.bold))
            Text(tr("It builds your games for Cartouche on the iPhone, and builds them again each time nxnative makes them better.",
                    "Il construit vos jeux pour Cartouche sur l’iPhone, et les reconstruit à chaque fois que nxnative les améliore."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "sparkles", text: tr("Follows every game you have, and says when nxnative improved one.", "Suit chacun de vos jeux, et vous dit quand nxnative en a amélioré un."))
                Feature(symbol: "externaldrive.connected.to.line.below", text: tr("Your games on this Mac or on your NAS, without filling the disk.", "Vos jeux sur ce Mac ou sur votre NAS, sans remplir le disque."))
                Feature(symbol: "iphone.radiowaves.left.and.right", text: tr("Cartouche installs them from this Mac, over your Wi-Fi.", "Cartouche les installe depuis ce Mac, par votre Wi-Fi."))
            }
            .padding(.top, 8)
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("This Mac’s tools", "Les outils du Mac"))
                        .font(.title.weight(.bold))
                    Text(tr("What nxnative builds with, installed for you. macOS may ask your password, and Xcode comes from the App Store.",
                            "Ce avec quoi nxnative construit, installé pour vous. macOS peut demander votre mot de passe, et Xcode vient de l’App Store."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                SetupButtons()
            }
            ScrollView {
                SetupList()
            }
        }
        .task { await setup.refresh() }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Your games", "Vos jeux"))
                .font(.title.weight(.bold))
            Text(tr("Choose where your dumps are and where the IPAs go. Both can be on your NAS: connect its share in the Finder first.",
                    "Choisissez où sont vos dumps et où vont les IPA. Les deux peuvent être sur votre NAS : connectez son partage dans le Finder d’abord."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                FolderField(title: tr("Game sources", "Sources des jeux"),
                            help: tr("One folder per game, with its dump.", "Un dossier par jeu, avec son dump."),
                            path: model.config?.sources ?? "") { path in model.update { $0.sources = path } }
                FolderField(title: tr("Games folder", "Dossier des jeux"),
                            help: tr("Where the IPAs go, for Cartouche.", "Où vont les IPA, pour Cartouche."),
                            path: model.config?.games ?? "") { path in model.update { $0.games = path } }
                KeysField()
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if model.engine == nil {
                Label(tr("The folders can be chosen once the tools are installed.", "Les dossiers se choisissent une fois les outils installés."), systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iphone: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("Cartouche on the iPhone", "Cartouche sur l’iPhone"))
                .font(.title.weight(.bold))
            Text(tr("On, this Mac becomes a storage place Cartouche can add: it installs your games and keeps your saves here, encrypted on the way, after you pair the iPhone once.",
                    "Activé, ce Mac devient un stockage que Cartouche peut ajouter : il y installe vos jeux et y garde vos sauvegardes, chiffrées en chemin, une fois l’iPhone associé."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Card {
                Toggle(isOn: Binding(get: { bridge.enabled }, set: { bridge.setEnabled($0) })) {
                    Label(tr("Share with Cartouche on the iPhone", "Partager avec Cartouche sur l’iPhone"), systemImage: "iphone.radiowaves.left.and.right")
                        .font(.headline)
                }
                .toggleStyle(.switch)
            }
            Text(tr("You can change it later on the iPhone page. Your games folder works with Cartouche’s other storage too (your NAS, a cloud).",
                    "Vous pourrez le changer plus tard sur la page iPhone. Votre dossier des jeux marche aussi avec les autres stockages de Cartouche (votre NAS, un cloud)."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Feature: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Theme.gradient)
                .frame(width: 32)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app's icon, as the Finder shows it.
struct AppIconView: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
