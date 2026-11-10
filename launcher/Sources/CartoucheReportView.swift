//
//  CartoucheReportView.swift
//  Cartouche
//
//  System › Report a problem: the player writes what happened, sees all
//  the report holds, and sends it themselves: with the share sheet
//  (Messages, Mail, AirDrop…), by copying it, or on GitHub's bug report
//  form, filled in for them to check and post. The report leaves the
//  iPhone only when the player sends it.
//
//  The report is the one Cartouche writes of an error (CartoucheReports),
//  without an error: Cartouche and this iPhone, the last steps, then the
//  last errors' reports, all cleaned of anything personal; and this
//  iPhone's memory limit as an entry of catalog/devices.json
//  (CartoucheProblemReport.swift), which holds nothing personal.
//

import SwiftUI
import UIKit

@available(iOS 17.0, *)
struct CartoucheReportView: View {
    @State private var what = ""
    @State private var copied = false
    @State private var gathered: Gathered?

    /// What Cartouche knows when the page opens.
    private struct Gathered {
        var report: String
        var errors: [String]
        var measurement: CartoucheDeviceMeasurement?
    }

    /// The last errors that go with a report: the five newest of the week.
    static let errorCount = 5
    static let errorAge: TimeInterval = 7 * 86_400

    var body: some View {
        let report = problemReport
        List {
            Section {
                TextField(CartoucheText.reportWhatPrompt, text: $what, axis: .vertical)
                    .lineLimit(5...12)
            } header: {
                Text(CartoucheText.reportWhat)
            } footer: {
                Text(CartoucheText.reportWhatFooter)
            }

            Section {
                ShareLink(item: report.text, subject: Text(verbatim: report.title)) {
                    Label(CartoucheText.reportSend, systemImage: "square.and.arrow.up")
                }
                Button(copied ? CartoucheText.reportCopied : CartoucheText.reportCopy,
                       systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = report.text
                    copied = true
                }
                if let url = report.issueURL(repository: Self.repository) {
                    Link(destination: url) {
                        Label(CartoucheText.reportGitHub, systemImage: "ladybug")
                    }
                }
            } footer: {
                Text(CartoucheText.reportSendFooter)
            }
            .disabled(gathered == nil)

            Section {
                Text(verbatim: report.details)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text(CartoucheText.reportContents)
            } footer: {
                Text(CartoucheText.reportPrivacy)
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(CartoucheText.reportTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if gathered == nil { gathered = Self.gather() }
        }
        .onChange(of: what) {
            copied = false
        }
    }

    private var problemReport: CartoucheProblemReport {
        CartoucheProblemReport(what: what, report: gathered?.report ?? "", errors: gathered?.errors ?? [],
                               measurement: gathered?.measurement, version: Self.version,
                               model: CartoucheDevice.modelIdentifier, iOS: CartoucheDevice.iOSVersion)
    }

    @MainActor
    private static func gather(now: Date = Date()) -> Gathered {
        let report = CartoucheReport(title: "Problem report", message: "", environment: CartoucheReports.environment(),
                                     journal: CartoucheReports.journal(last: 50))
        let errors = CartoucheReports.recent
            .filter { now.timeIntervalSince($0.date) < errorAge }
            .prefix(errorCount)
            .map { CartoucheReports.text(of: $0) }
        return Gathered(report: CartoucheReports.text(of: report), errors: Array(errors), measurement: measurement(now: now))
    }

    /// This iPhone's memory limit, now, as devices.json records it; nil on a
    /// simulator, or when iOS gives no limit.
    static func measurement(now: Date) -> CartoucheDeviceMeasurement? {
        let model = CartoucheDevice.modelIdentifier
        guard CartoucheDeviceMeasurement.isModelIdentifier(model), let memory = CartoucheMemoryReading.now() else {
            return nil
        }
        let known = CartoucheCatalog.shared.device(model)
        return CartoucheDeviceMeasurement(
            identifier: model, chip: known?.chip,
            memoryGB: known?.memoryGB ?? CartoucheDeviceMeasurement.memoryGB(physicalMemory: ProcessInfo.processInfo.physicalMemory),
            date: CartoucheDeviceMeasurement.day(now), iOS: CartoucheDevice.iOSVersion,
            increasedMemoryLimit: CartoucheDevice.hasIncreasedMemoryLimit, appMemoryLimitMiB: memory.limitMiB)
    }

    /// Cartouche's version and the commit it was built from
    /// (app/scripts/package.sh), as the System page shows it.
    static var version: String {
        let info = Bundle.main.infoDictionary
        var text = info?["CFBundleShortVersionString"] as? String ?? "?"
        if let build = info?["LCVersionInfo"] as? String, !build.isEmpty {
            text += " (" + build + ")"
        }
        return text
    }

    /// The repository of Cartouche's own source, whose bug report form the
    /// report fills in.
    static var repository: String {
        CartoucheProblemReport.repository(sourceURL: Bundle.main.object(forInfoDictionaryKey: "CartoucheSourceURL") as? String)
    }
}
