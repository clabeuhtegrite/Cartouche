//
//  Theme.swift
//  Cartouche Builder
//
//  Cartouche's colours (app/icon/make_icon.py: indigo to pink), the cards
//  the pages are made of, and a game's state as the library shows it.
//

import BuilderKit
import SwiftUI

enum Theme {
    static let indigo = Color(red: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255)
    static let pink = Color(red: 0xEC / 255, green: 0x48 / 255, blue: 0x99 / 255)
    static let gradient = LinearGradient(colors: [indigo, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let corner: CGFloat = 14
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            )
    }
}

/// A page's title and what it is about, above its cards.
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String = "") {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// How a game is, in the library: its words, its colour and its symbol.
struct GameLook {
    let text: String
    let color: Color
    let symbol: String

    init(_ game: Game, progress: GameProgress?) {
        if let progress {
            if progress.state == "building" {
                let percent = (progress.overall ?? progress.frac).map { " " + Format.percent($0) } ?? ""
                text = tr("Building", "Construction") + percent
                color = Theme.indigo
                symbol = "hammer.fill"
            } else {
                text = tr("Waiting its turn", "En attente")
                color = .secondary
                symbol = "clock.fill"
            }
            return
        }
        switch game.state {
        case .due:
            let own = game.changeCounts?.own ?? 0
            if game.reasons == ["new"] {
                text = tr("Never built", "Jamais construit")
            } else if own > 0 {
                text = tr("Improved: \(own) change\(own == 1 ? "" : "s")", "Amélioré : \(own) changement\(own == 1 ? "" : "s")")
            } else {
                text = tr("To rebuild", "À reconstruire")
            }
            color = .orange
            symbol = "sparkles"
        case .upToDate:
            text = tr("Up to date", "À jour")
            color = .green
            symbol = "checkmark.circle.fill"
        case .failed:
            text = tr("Build failed", "Échec de construction")
            color = .red
            symbol = "exclamationmark.triangle.fill"
        case .notFollowed:
            text = tr("Not followed", "Pas suivi")
            color = .secondary
            symbol = "pause.circle.fill"
        case .noProfile:
            text = tr("No nxnative profile", "Sans profil nxnative")
            color = .secondary
            symbol = "questionmark.circle.fill"
        case .noSource:
            text = tr("IPA only", "IPA seule")
            color = .teal
            symbol = "shippingbox.fill"
        case .building:
            text = tr("Building", "Construction")
            color = Theme.indigo
            symbol = "hammer.fill"
        case .queued:
            text = tr("Waiting its turn", "En attente")
            color = .secondary
            symbol = "clock.fill"
        case .unknown:
            text = "—"
            color = .secondary
            symbol = "circle"
        }
    }
}

/// A reason a game is due, in the player's words.
func reasonText(_ reason: String) -> String {
    switch reason {
    case "new": return tr("Never built", "Jamais construit")
    case "missing": return tr("Its IPA is missing", "Son IPA a disparu")
    case "source": return tr("New files in its folder", "Nouveaux fichiers dans son dossier")
    case "profile": return tr("nxnative changed its profile", "nxnative a changé son profil")
    case "named": return tr("A fix of nxnative names it", "Un correctif de nxnative le nomme")
    case "shared": return tr("nxnative’s shared code changed", "Le code commun de nxnative a changé")
    case "toolchain": return tr("Xcode changed", "Xcode a changé")
    case "unknown_base": return tr("Built from a commit main no longer has", "Construit depuis un commit absent de main")
    case "failed_here": return tr("Failed at this commit of nxnative", "Échec à ce commit de nxnative")
    case "up_to_date": return tr("Up to date", "À jour")
    case "forced": return tr("Asked for", "Demandé")
    default: return reason
    }
}

/// A commit's kind, as a small label.
func changeKindText(_ kind: String) -> String {
    switch kind {
    case "profile": return tr("Profile", "Profil")
    case "named": return tr("Fix", "Correctif")
    default: return tr("Shared", "Commun")
    }
}

/// A batch step's name, in the player's words.
func stageText(_ stage: String?) -> String {
    switch stage ?? "" {
    case "": return tr("Getting ready", "Préparation")
    case "unpack": return tr("Unpacking the game", "Décompression du jeu")
    case "extract": return tr("Extracting the game", "Extraction du jeu")
    case "shaders", "shader": return tr("Compiling shaders for the iPhone", "Compilation des shaders pour l’iPhone")
    case "build", "xcode": return tr("Building the app", "Construction de l’app")
    case "pack", "package", "ipa": return tr("Packing the IPA", "Empaquetage de l’IPA")
    case "deliver": return tr("Copying to the games folder", "Copie dans le dossier des jeux")
    default: return stage ?? ""
    }
}
