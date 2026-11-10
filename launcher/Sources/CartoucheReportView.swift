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
//  with what the player wrote as its message: Cartouche and this iPhone,
//  the last steps, then the last errors' reports, all redacted, what the
//  player wrote included; and this iPhone's memory limit as an entry of
//  catalog/devices.json, which holds nothing personal
//  (CartoucheProblemReport.swift).
//

import SwiftUI
import UIKit

@available(iOS 17.0, *)
struct CartoucheReportView: View {
    @State private var what = ""
    @State private var copied = false
    @State private var gathered: Gathered?
    @Environment(\.openURL) private var openURL

    /// What Cartouche knows when the page opens.
    private struct Gathered {
        var environment: CartoucheReport.Environment
        var journal: [String]
        var date: Date
        var errors: [String]
        var measurement: CartoucheDeviceMeasurement?
        var redaction: CartoucheRedaction
    }

    /// The last errors that go with a report: the five newest of the week.
    static let errorCount = 5
    static let errorAge: TimeInterval = 7 * 86_400

    var body: some View {
        let report = problemReport
        let parts = report?.parts ?? []
        let text = parts.joined(separator: "\n\n")
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
                ShareLink(item: text, subject: Text(verbatim: report?.title ?? "")) {
                    Label(CartoucheText.reportSend, systemImage: "square.and.arrow.up")
                }
                Button(copied ? CartoucheText.reportCopied : CartoucheText.reportCopy,
                       systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = text
                    copied = true
                }
                Button(CartoucheText.reportGitHub, systemImage: "ladybug") {
                    // Made when asked: the form's address can take a while
                    // to shorten.
                    if let url = report?.issueURL(repository: Self.repository) {
                        openURL(url)
                    }
                }
            } footer: {
                Text(CartoucheText.reportSendFooter)
            }
            .disabled(report == nil)

            Section {
                // One part each, so that typing lays out only the first.
                ForEach(parts.indices, id: \.self) { index in
                    Text(verbatim: parts[index])
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

    private var problemReport: CartoucheProblemReport? {
        guard let gathered else { return nil }
        return CartoucheProblemReport(what: what, environment: gathered.environment, journal: gathered.journal,
                                      date: gathered.date, errors: gathered.errors, measurement: gathered.measurement,
                                      redaction: gathered.redaction)
    }

    @MainActor
    private static func gather(now: Date = Date()) -> Gathered {
        let errors = CartoucheReports.recent
            .filter { now.timeIntervalSince($0.date) < errorAge }
            .prefix(errorCount)
            .map { CartoucheReports.text(of: $0) }
        return Gathered(environment: CartoucheReports.environment(),
                        journal: CartoucheReports.journal(last: CartoucheReports.journalShown),
                        date: now, errors: Array(errors), measurement: measurement(now: now),
                        redaction: CartoucheReports.redaction())
    }

    /// This iPhone's memory limit, now, as devices.json records it; nil on a
    /// simulator, or when iOS gives no limit.
    @MainActor
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

    /// The repository of Cartouche's own source, whose bug report form the
    /// report fills in.
    static var repository: String {
        CartoucheProblemReport.repository(sourceURL: Bundle.main.object(forInfoDictionaryKey: "CartoucheSourceURL") as? String)
    }
}
