//
//  HarnessSideStore.swift
//  CartoucheHarness
//
//  The built-in SideStore's renewal, as the launcher reaches it: the class
//  CartoucheRefresh of SideStoreSupport (launcher/SideStoreSupport), which
//  LiveContainer loads with the built-in SideStore, and the record of
//  Cartouche's signature SideStore keeps for its widget, which Cartouche
//  reads its expiry from (CartoucheSignature). Here SideStore renews as a
//  test says (HarnessLC.renewal): it records each call, takes
//  HarnessLC.renewalTime, then records the new expiry and answers, or
//  fails with SideStore's words.
//

import Foundation

enum HarnessSideStore {
    /// How a renewal goes.
    enum Renewal: Equatable {
        /// Renewed: the signature lasts DAYS from then.
        case renews(days: Double)
        /// SideStore fails with this message, Cartouche not renewed.
        case fails(String)
    }

    /// Records Cartouche's signature as expiring DAYS from now, as SideStore
    /// does once it has renewed it, in widget_data.json in the app group.
    static func record(expiringIn days: Double, renewed: Date = Date()) {
        let record: [String: Any] = [
            "allApps": [[
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "expirationDate": Date().addingTimeInterval(days * 86_400).timeIntervalSinceReferenceDate,
                "refreshedDate": renewed.timeIntervalSinceReferenceDate,
            ]],
        ]
        let data = try? JSONSerialization.data(withJSONObject: record)
        try? data?.write(to: LCSharedUtils.appGroupPath().appendingPathComponent("widget_data.json"), options: .atomic)
    }
}

/// Renews Cartouche as HarnessLC.renewal says, as the System page, and
/// Cartouche by itself, ask SideStore through LiveContainer's bridge.
@objc(CartoucheRefresh)
final class HarnessRefresh: NSObject {
    /// `progress` counts to 100; `completion` runs on the main queue, with
    /// nil or the error's text.
    @objc(refreshAllAppsWithProgress:completion:)
    static func refreshAllApps(progress: Progress, completion: @escaping (String?) -> Void) {
        HarnessLC.renewals.append(Date())
        let renewal = HarnessLC.renewal
        progress.totalUnitCount = 100
        progress.completedUnitCount = 10
        DispatchQueue.main.asyncAfter(deadline: .now() + HarnessLC.renewalTime) {
            switch renewal {
            case .renews(let days):
                HarnessSideStore.record(expiringIn: days)
                progress.completedUnitCount = 100
                completion(nil)
            case .fails(let message):
                completion(message)
            }
        }
    }
}
