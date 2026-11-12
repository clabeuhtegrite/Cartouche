//
//  CartoucheGameFit.swift
//  Cartouche
//
//  How a game fits this iPhone, from its sheet and what was measured here:
//  the rule, which CartoucheFit (CartoucheDevice.swift) puts into words on
//  the game's sheet. nxnative refuses a GPU that cannot read BC-compressed
//  textures for every game, the A16's and older, whatever the game's sheet
//  says and for a game without a sheet too: players with an iPhone 13 Pro
//  or an iPhone 15 saw their games close before their first image
//  (docs/decisions.md, 67).
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

enum CartoucheGameFit {
    /// Why a game does not fit.
    enum Reason: Hashable {
        /// This iOS is older than MINIMUM, which the game needs.
        case iOS(minimum: String)
        /// The GPU cannot read BC-compressed textures.
        case gpu
        /// The game needs Increased Memory Limit, which Cartouche's
        /// signature lacks.
        case increasedMemoryLimit
        /// The game's peak, NEEDEDMIB, is above the memory it has here,
        /// LIMITMIB.
        case memory(neededMiB: Int, limitMiB: Int)
        /// The testers' last result on this model: it does not run.
        case doesNotRun
    }

    enum Verdict: Hashable {
        /// Testers ran it on this model, and nothing here stands in the way.
        case recommended
        /// Nothing stands in the way, but nobody has tried this model yet.
        case untested
        /// It may start, but the reasons say why it should not be expected to.
        case notRecommended([Reason])
        /// iOS or the GPU cannot run it.
        case unsupported([Reason])
    }

    /// The verdict for a game with a sheet: MINIMUMIOS, the iOS it needs,
    /// which this iPhone runs, RUNSMINIMUMIOS, or not; READSBCTEXTURES,
    /// whether this iPhone's GPU reads BC-compressed textures; NEEDSIML,
    /// whether the game needs Increased Memory Limit, which Cartouche's
    /// signature has, HASIML, or not; PEAKMIB, the most the game used,
    /// against LIMITMIB, the memory it has here, where Play starts it;
    /// LATESTHERE, the status of the testers' last result on this model.
    static func verdict(minimumIOS: String, runsMinimumIOS: Bool, readsBCTextures: Bool,
                        needsIML: Bool, hasIML: Bool, peakMiB: Int?, limitMiB: Int?,
                        latestHere: String?) -> Verdict {
        var blockers: [Reason] = []
        if !runsMinimumIOS { blockers.append(.iOS(minimum: minimumIOS)) }
        if !readsBCTextures { blockers.append(.gpu) }
        if !blockers.isEmpty { return .unsupported(blockers) }

        var warnings: [Reason] = []
        if needsIML && !hasIML { warnings.append(.increasedMemoryLimit) }
        if let peakMiB, let limitMiB, peakMiB > limitMiB {
            warnings.append(.memory(neededMiB: peakMiB, limitMiB: limitMiB))
        }
        if latestHere == "does-not-run" { warnings.append(.doesNotRun) }
        if !warnings.isEmpty { return .notRecommended(warnings) }
        if latestHere == "playable" || latestHere == "playable-with-issues" { return .recommended }
        return .untested
    }

    /// The verdict for a game without a sheet, of which nothing is known
    /// but what this iPhone says, READSBCTEXTURES: nil when that is
    /// nothing against it.
    static func verdictWithoutSheet(readsBCTextures: Bool) -> Verdict? {
        readsBCTextures ? nil : .unsupported([.gpu])
    }
}
