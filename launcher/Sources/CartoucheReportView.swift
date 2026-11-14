//
//  CartoucheReportView.swift
//  Cartouche
//
//  System › Report a problem: the player writes what happened, sees all
//  the report holds, and sends it themselves: with Send to Cartouche, to
//  Cartouche's server, which files it in the project's private repository
//  (telemetry/worker.js, POST /v1/problems); with the share sheet
//  (Messages, Mail, AirDrop…); by copying it; or on GitHub's bug report
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
    @State private var sending = Sending.ready
    /// The number of the report Send to Cartouche sends: the same when it
    /// tries again, a new one once a report is sent.
    @State private var submissionID = CartoucheProblemSubmission.newID()
    @Environment(\.openURL) private var openURL

    /// Where Send to Cartouche is.
    enum Sending: Equatable {
        case ready
        case sending
        case sent
        case failed(String)
    }

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
                if let endpoint = CartoucheTelemetry.endpoint {
                    Button {
                        send(report, to: endpoint)
                    } label: {
                        sendLabel
                    }
                    .disabled(sending == .sending || sending == .sent)
                    if case .failed(let reason) = sending {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
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
                Text(CartoucheTelemetry.endpoint == nil ? CartoucheText.reportSendFooter : CartoucheText.reportSendFooterServer)
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
            if sending != .sending {
                sending = .ready
            }
        }
    }

    @ViewBuilder
    private var sendLabel: some View {
        switch sending {
        case .sending:
            Label {
                Text(CartoucheText.reportSending)
            } icon: {
                ProgressView()
            }
        case .sent:
            Label(CartoucheText.reportSent, systemImage: "checkmark.circle.fill")
        case .ready, .failed:
            Label(CartoucheText.reportSendToCartouche, systemImage: "paperplane")
        }
    }

    // MARK: Send to Cartouche

    private func send(_ report: CartoucheProblemReport?, to endpoint: URL) {
        guard let submission = report?.submission(id: submissionID), let body = try? submission.json() else { return }
        sending = .sending
        Task {
            let sent = await Self.post(body, to: endpoint)
            sending = sent
            if sent == .sent {
                CartoucheReports.note("Problem report sent to Cartouche")
                submissionID = CartoucheProblemSubmission.newID()
            }
        }
    }

    private static let session = URLSession(configuration: .ephemeral)

    /// Posts BODY to the server's problems route: sent once the server has
    /// it, whether GitHub has it yet or not. A game's log goes the same way
    /// (CartoucheGameLogView).
    static func post(_ body: Data, to endpoint: URL) async -> Sending {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/problems"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return .sent
            case 429:
                return .failed(CartoucheText.reportSendTooMany)
            default:
                CartoucheReports.note("Problem report refused by Cartouche's server: HTTP \(status)")
                return .failed(CartoucheText.reportSendRefused)
            }
        } catch {
            return .failed(CartoucheText.reportSendUnreachable(error.localizedDescription))
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
