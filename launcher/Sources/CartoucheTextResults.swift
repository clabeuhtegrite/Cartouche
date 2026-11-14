//
//  CartoucheTextResults.swift
//  Cartouche
//
//  The words Cartouche says of a result its game measurements made, under
//  Testers' results on a game's sheet (CartoucheMeasuredNote.swift), in
//  Cartouche.xcstrings with the rest of the launcher's words: the app takes
//  them from CartoucheText.s, the tests from the catalogue itself. Their
//  English is what telemetry/sheets.py writes, but for its dates.
//  Foundation only, so that swift test checks them on a Mac
//  (launcher/Package.swift).
//

import Foundation

/// The words of a measured result, with LOCALE's numbers.
struct CartoucheMeasuredWords {
    /// The words of a key, from its English: CartoucheText.s in the app.
    let text: (_ key: String, _ english: String) -> String
    let locale: Locale

    private func s(_ key: String, _ english: String) -> String {
        text(key, english)
    }

    private func f(_ key: String, _ english: String, _ arguments: CVarArg...) -> String {
        String(format: text(key, english), locale: locale, arguments: arguments)
    }

    /// Measured by Cartouche on DEVICES iPhones, or iPads, SESSIONS
    /// sessions (PERIOD).
    func lead(devices: Int, iPads: Bool, sessions: Int, period: String) -> String {
        if iPads {
            return f("results.measured.iPads", "Measured by Cartouche on %1$lld iPads, %2$lld sessions (%3$@)", devices, sessions, period)
        }
        return f("results.measured", "Measured by Cartouche on %1$lld iPhones, %2$lld sessions (%3$@)", devices, sessions, period)
    }

    /// The median frame rate, for the rate the game asks for when it is
    /// known.
    func fps(_ fps: String, target: Int?) -> String {
        guard let target else { return f("results.fps", "%@ fps (median)", fps) }
        return f("results.fps.target", "%1$@ fps for %2$lld (median)", fps, target)
    }

    func slowest(_ fps: String) -> String {
        f("results.slowest", "%@ fps in the slowest 5%% of the time", fps)
    }

    func stutters(_ perMinute: String) -> String {
        f("results.stutters", "%@ stutters a minute", perMinute)
    }

    /// LEAD: FIGURES. ENDING
    func withFigures(_ lead: String, _ figures: String, _ ending: String) -> String {
        f("results.figures", "%1$@: %2$@. %3$@", lead, figures, ending)
    }

    /// LEAD. ENDING
    func withoutFigures(_ lead: String, _ ending: String) -> String {
        f("results.noFigures", "%1$@. %2$@", lead, ending)
    }

    var noneEndedBadly: String {
        s("results.ended.none", "None ended badly.")
    }

    /// COUNT sessions ended badly: HOW. HOW is nil for a sheet that does not
    /// say how.
    func endedBadly(_ count: Int, how: String?) -> String {
        switch (count, how) {
        case (1, let how?): return f("results.ended.one.how", "1 session ended badly: %@.", how)
        case (_, let how?): return f("results.ended.how", "%1$lld sessions ended badly: %2$@.", count, how)
        case (1, nil): return s("results.ended.one", "1 session ended badly.")
        case (_, nil): return f("results.ended", "%lld sessions ended badly.", count)
        }
    }

    func crashes(_ count: Int) -> String {
        count == 1 ? s("results.crash", "1 crash") : f("results.crashes", "%lld crashes", count)
    }

    func outOfMemory(_ count: Int) -> String {
        f("results.outOfMemory", "%lld out of memory", count)
    }

    func didNotStart(_ count: Int) -> String {
        count == 1 ? s("results.didNotStart.one", "1 did not start") : f("results.didNotStart", "%lld did not start", count)
    }

    var buildNotReported: String {
        s("results.build.notReported", "nxnative, its build not reported")
    }

    /// nxnative COMMIT and OTHERS other builds.
    func builds(_ commit: String, others: Int) -> String {
        if others == 1 {
            return f("results.builds.one", "nxnative %@ and 1 other build", commit)
        }
        return f("results.builds", "nxnative %1$@ and %2$lld other builds", commit, others)
    }
}
