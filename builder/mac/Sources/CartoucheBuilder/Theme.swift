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

/// The window's columns: the sidebar, the page, and the game's sheet beside
/// the library. The sheet is a column of the library's own, of one width,
/// not the system's inspector: on macOS 27 the inspector, inside the split
/// view's page, made the page wider than the window at each update, the
/// page and the sidebar spilled past both edges, and AppKit went round its
/// constraint passes until it ended the app (11 November). The window's
/// least width holds the sidebar at its widest, a page and the sheet; each
/// page lays itself out to fit (PageHeader, DueCard), and the layout check
/// (LayoutCheck.swift) holds them to it.
enum Columns {
    static let sidebar: (least: CGFloat, ideal: CGFloat, most: CGFloat) = (200, 220, 280)
    static let page: CGFloat = 340
    static let sheet: CGFloat = 320
    static let window = CGSize(width: sidebar.most + page + sheet, height: 620)
}

/// A page's title and what it is about, above its cards, with its button
/// or its picker beside it, or under it when the page is too narrow.
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var accessory: Accessory

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titles
                Spacer(minLength: 12)
                accessory
            }
            VStack(alignment: .leading, spacing: 14) {
                titles
                accessory
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
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
                // Its app for this Mac, after its IPA or alone.
                text = (progress.buildsMac && progress.onMacNow ? tr("Building for this Mac", "Construction pour ce Mac") : tr("Building", "Construction")) + percent
                color = Theme.indigo
                symbol = progress.buildsMac && progress.onMacNow ? "macbook" : "hammer.fill"
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
            } else if !game.reasons.isEmpty, game.reasons.allSatisfy({ $0.hasPrefix("mac_") }) {
                // Its IPA up to date, its app for this Mac to build.
                text = tr("To build for this Mac", "À construire pour ce Mac")
                color = .orange
                symbol = "macbook"
                return
            } else if own > 0 {
                text = tr("Improved: \(own) change\(own == 1 ? "" : "s")", "Amélioré : \(own) changement\(own == 1 ? "" : "s")")
            } else {
                text = tr("To rebuild", "À reconstruire")
            }
            color = .orange
            symbol = "sparkles"
        case .upToDate where game.mac?.failed == true:
            // Its IPA up to date, its Mac app failed at this nxnative commit.
            text = tr("Mac app failed", "Échec de l’app Mac")
            color = .orange
            symbol = "exclamationmark.triangle.fill"
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
    case "not_selected": return tr("Not followed: rebuilt only when asked", "Pas suivi : reconstruit seulement à la demande")
    case "no_profile": return tr("nxnative has no profile for it yet: built once it has one", "nxnative n’a pas encore de profil pour lui : construit dès qu’il en aura un")
    case "no_source": return tr("Its dump is not in the sources folder: its IPA is shown, and rebuilt once the dump is back",
                                "Son dump n’est pas dans le dossier des sources : son IPA est montrée, et reconstruite quand il reviendra")
    case "mac_new": return tr("Not on this Mac yet: its Mac app is built", "Pas encore sur ce Mac : son app Mac est construite")
    case "mac_missing": return tr("Its Mac app is missing", "Son app Mac a disparu")
    case "mac_behind": return tr("Its Mac app is older than its IPA", "Son app Mac est plus ancienne que son IPA")
    case "no_platform": return tr("Built neither for the iPhone nor for this Mac: turn one of the two on below",
                                  "Construit ni pour l’iPhone ni pour ce Mac : activez l’un des deux ci-dessous")
    default: return reason
    }
}

/// A reason a game is due, with how many of nxnative's commits it comes
/// from: never a commit's own words, which are English and long (the
/// sheet lists the commits below).
func whyText(_ reason: String, counts: ChangeCounts?) -> String {
    switch reason {
    case "profile":
        let count = counts?.profile ?? 0
        guard count > 1 else { return reasonText(reason) }
        return tr("nxnative changed its profile (\(count) commits)", "nxnative a changé son profil (\(count) commits)")
    case "named":
        let count = counts?.named ?? 0
        guard count > 1 else { return reasonText(reason) }
        return tr("\(count) fixes of nxnative name it", "\(count) correctifs de nxnative le nomment")
    case "shared":
        let count = counts?.shared ?? 0
        guard count > 1 else { return reasonText(reason) }
        return tr("nxnative’s shared code changed (\(count) commits)", "Le code commun de nxnative a changé (\(count) commits)")
    default:
        return reasonText(reason)
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
    // Its app for this Mac (nxnative's --platform mac-app, then macapps.py).
    case "Mac shaders": return tr("Compiling shaders for this Mac", "Compilation des shaders pour ce Mac")
    case "Mac host": return tr("Building the game for this Mac", "Construction du jeu pour ce Mac")
    case "Pipeline prebuild", "Pipeline archive", "Prewarm pipelines":
        return tr("Preparing its graphics for this Mac", "Préparation de ses graphismes pour ce Mac")
    case "Mac app": return tr("Packing the Mac app", "Assemblage de l’app Mac")
    case "mac_deliver": return tr("Putting the app on this Mac", "Mise en place de l’app sur ce Mac")
    default: return stage ?? ""
    }
}
