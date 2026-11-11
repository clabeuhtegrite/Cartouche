//
//  CartoucheContinuedWork.swift
//  Cartouche
//
//  A game's transfer that goes on once the player leaves Cartouche, with
//  how far it has gone where they can see it. From iOS 26, a step the
//  player started with a tap can ask iOS to go on with it in the
//  background, as a continued processing task (BGContinuedProcessingTask):
//  iOS keeps Cartouche running until the step is over, its connections to
//  the player's storage too, and shows the step in a Live Activity of its
//  own, on the Lock Screen and in the Dynamic Island, with a button that
//  stops it. CartoucheGameActions asks for one for each install and each
//  copy to the games folder; never for the saves, which go on their own
//  and which iOS would not take for a step the player started.
//
//  It takes nothing an Apple ID without a paid membership lacks: no
//  entitlement, no extension, so no App ID of its own, and the App ID's
//  increased memory limit stays as it is. iOS runs only a task whose
//  identifier starts with the bundle identifier the app runs as, and that
//  the app's Info.plist lists under BGTaskSchedulerPermittedIdentifiers,
//  where app/scripts/package.sh puts "<bundle identifier>.transfer.*".
//  Signing gives Cartouche its bundle identifier followed by the team's,
//  and the Cartouche Installer (isideload) and the built-in SideStore
//  (ResignAppOperation) move the identifiers of that list under it.
//
//  Before iOS 26, when iOS will not run the task now, or until it has
//  started, the step has the half-minute iOS gives any app once it leaves
//  the screen (CartoucheGameActions): it pauses once that is over, and goes
//  on when the player comes back.
//
//  iOS gives no way to tell a stop from the Live Activity from one of its
//  own. Either stops the step, unless the player is back in Cartouche,
//  where they see it go on, or the game is in place already
//  (CartoucheGameActions.stopFromOutside).
//

import BackgroundTasks
import UIKit

@MainActor
final class CartoucheContinuedWork {
    static let shared = CartoucheContinuedWork()

    /// What every identifier holds after the bundle identifier, before the
    /// step's own end; app/scripts/package.sh lists "<bundle
    /// identifier>.transfer.*".
    nonisolated static let context = "transfer"
    /// The units iOS reads a step's progress in: thousandths.
    private static let units: Int64 = 1_000

    /// The step under way, from the request for it until it ends.
    private var identifier: String?
    /// The task iOS runs the step in, once it has started.
    private var task: BGTask?
    private var outside: (@MainActor (Bool) -> Void)?
    private var stop: (@MainActor () -> Void)?
    /// What the Live Activity shows: the step's title, what it does now,
    /// and how far it has gone, in thousandths.
    private var title = ""
    private var subtitle = ""
    private var done: Int64 = 0

    /// "<bundle identifier>.transfer.", the beginning of every identifier,
    /// when this iOS runs continued processing tasks and the Info.plist
    /// lists them under the bundle identifier Cartouche runs as; nil
    /// otherwise.
    nonisolated static var prefix: String? {
        guard #available(iOS 26.0, *), let bundleID = Bundle.main.bundleIdentifier,
              let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        else { return nil }
        return permitted.contains("\(bundleID).\(context).*") ? "\(bundleID).\(context)." : nil
    }

    /// Asks iOS to go on with WORK once the player leaves Cartouche, as the
    /// player starts it. OUTSIDE says whether iOS goes on with it there:
    /// true once iOS runs it, false if iOS stops it while the player is in
    /// Cartouche, where it goes on. STOP runs when the player stops it from
    /// the Live Activity, or iOS does, while Cartouche is in the background.
    func begin(_ work: CartoucheGameWork, outside: @escaping @MainActor (Bool) -> Void,
               stop: @escaping @MainActor () -> Void) {
        end(success: false)
        guard #available(iOS 26.0, *) else { return }
        guard let prefix = Self.prefix else {
            CartoucheReports.note(work.title + ": iOS cannot go on with it outside Cartouche, "
                                  + "whose Info.plist names no step under the bundle identifier it runs as")
            return
        }
        let identifier = prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Once for each identifier: iOS ends an app that registers one
        // twice. On the main queue, where the step is.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { CartoucheContinuedWork.shared.run(task, identifier: identifier) }
        }
        guard registered else {
            CartoucheReports.note(work.title + ": iOS did not take the identifier to go on with it outside Cartouche")
            return
        }
        self.identifier = identifier
        self.outside = outside
        self.stop = stop
        self.title = work.title
        self.subtitle = Self.subtitle(of: work)
        self.done = Self.thousandths(of: work)
        let (shownTitle, shownSubtitle) = (self.title, self.subtitle)
        // Off the main thread, as iOS 27 asks. At once or not at all: a step
        // waiting in iOS's queue could start once it was over, or once iOS
        // had stopped Cartouche, and find no one to run it.
        Task.detached(priority: .userInitiated) {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: shownTitle, subtitle: shownSubtitle)
            request.strategy = .fail
            do {
                if #available(iOS 27.0, *) {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                } else {
                    try BGTaskScheduler.shared.submit(request)
                }
            } catch {
                let failure = error as NSError
                await CartoucheContinuedWork.shared.refused(identifier, because: "\(failure.domain) \(failure.code)")
            }
        }
    }

    /// Shows how far WORK has gone and what it does now, once iOS runs it.
    func update(_ work: CartoucheGameWork) {
        guard identifier != nil else { return }
        let title = work.title
        let subtitle = Self.subtitle(of: work)
        // Never backwards: iOS reads a step that goes back as one that is
        // stuck.
        let done = max(self.done, Self.thousandths(of: work))
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            if done != self.done {
                task.progress.completedUnitCount = done
            }
            if title != self.title || subtitle != self.subtitle {
                task.updateTitle(title, subtitle: subtitle)
            }
        }
        self.title = title
        self.subtitle = subtitle
        self.done = done
    }

    /// The step is over, and SUCCESS says how it went: iOS shows it on the
    /// Live Activity a moment, then takes it down.
    func end(success: Bool) {
        guard let identifier else { return }
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            if success {
                task.progress.completedUnitCount = Self.units
            }
            task.setTaskCompleted(success: success)
        } else {
            // Not run yet: nor ever.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        clear()
    }

    // MARK: What iOS does with it

    /// iOS runs the step, on the main queue: how far it has gone, and what
    /// it does now, go to the Live Activity, and Cartouche tells the player
    /// they can leave.
    private func run(_ task: BGTask, identifier: String) {
        guard #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask,
              identifier == self.identifier, self.task == nil else {
            // A step that ended before iOS ran it.
            task.setTaskCompleted(success: false)
            return
        }
        self.task = continued
        continued.progress.totalUnitCount = Self.units
        continued.progress.completedUnitCount = done
        continued.expirationHandler = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CartoucheContinuedWork.shared.expired(identifier) }
            }
        }
        if continued.title != title || continued.subtitle != subtitle {
            continued.updateTitle(title, subtitle: subtitle)
        }
        CartoucheReports.note(title + ": iOS goes on with it once the player leaves Cartouche")
        outside?(true)
    }

    /// The player stopped the step from the Live Activity, or iOS did: the
    /// task ends at once, as iOS asks, and so does the step, unless the
    /// player is back in Cartouche.
    private func expired(_ identifier: String) {
        guard identifier == self.identifier else { return }
        let (outside, stop) = (self.outside, self.stop)
        let inFront = UIApplication.shared.applicationState == .active
        CartoucheReports.note(title + (inFront ? ": iOS no longer goes on with it outside Cartouche, where the player is back"
                                               : ": stopped outside Cartouche, from the Live Activity or by iOS"))
        end(success: false)
        if inFront {
            outside?(false)
        } else {
            stop?()
        }
    }

    /// iOS will not run the step: it keeps its half-minute.
    private func refused(_ identifier: String, because reason: String) {
        guard identifier == self.identifier else { return }
        CartoucheReports.note(title + ": iOS will not go on with it outside Cartouche (" + reason + ")")
        clear()
    }

    private func clear() {
        identifier = nil
        task = nil
        outside = nil
        stop = nil
        title = ""
        subtitle = ""
        done = 0
    }

    // MARK: What the Live Activity says

    /// What the Live Activity says under the title: how far the step has
    /// gone, and where the game comes from or goes to, or what it does now.
    static func subtitle(of work: CartoucheGameWork) -> String {
        switch work.stage {
        case "signing":
            return CartoucheText.installSigning
        case "savesSync":
            return work.step
        case "reconnecting":
            if let place = work.place {
                return CartoucheText.outsideReconnecting(place)
            }
        default:
            break
        }
        let percent = work.fraction.map { min(max($0, 0), 1).formatted(.percent.precision(.fractionLength(0))) }
        switch (work.kind == .exporting, percent, work.place) {
        case (true, let percent?, let place?):
            return CartoucheText.outsideToPercent(percent, place)
        case (true, nil, let place?):
            return CartoucheText.outsideTo(place)
        case (false, let percent?, let place?):
            return CartoucheText.outsideFromPercent(percent, place)
        case (false, nil, let place?):
            return CartoucheText.outsideFrom(place)
        case (false, let percent?, nil):
            return CartoucheText.outsideUnpacking(percent)
        default:
            return percent ?? work.step
        }
    }

    /// How far WORK has gone, in thousandths.
    private static func thousandths(of work: CartoucheGameWork) -> Int64 {
        guard let fraction = work.fraction else { return 0 }
        return Int64((min(max(fraction, 0), 1) * Double(units)).rounded(.down))
    }
}
