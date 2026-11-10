//
//  CartoucheTelemetryView.swift
//  Cartouche
//
//  System › Game measurements: the switch of Cartouche's telemetry
//  (CartoucheTelemetry.swift), what it sends, the last report as it left,
//  and the way to have the server erase what this iPhone sent.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheTelemetryView: View {
    @ObservedObject private var telemetry = CartoucheTelemetry.shared
    @State private var confirmingErase = false
    @State private var eraseFailed = false

    var body: some View {
        List {
            Section {
                Toggle(CartoucheText.telemetrySend, isOn: Binding(get: { telemetry.isOn }, set: { telemetry.setOn($0) }))
            } footer: {
                Text(CartoucheText.telemetryFooter)
            }
            Section {
                Label(CartoucheText.telemetryWhatGames, systemImage: "gamecontroller")
                Label(CartoucheText.telemetryWhatDevice, systemImage: "iphone")
                Label(CartoucheText.telemetryWhatEvents, systemImage: "list.bullet.rectangle")
                Label(CartoucheText.telemetryWhatNever, systemImage: "hand.raised")
            } header: {
                Text(CartoucheText.telemetryWhat)
            }
            Section {
                LabeledContent(CartoucheText.telemetryLastSent,
                               value: telemetry.lastSent.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? CartoucheText.telemetryNever)
                LabeledContent(CartoucheText.telemetrySentCount, value: String(telemetry.sent))
                LabeledContent(CartoucheText.telemetryWaiting, value: String(telemetry.waiting))
                if let report = telemetry.lastReport {
                    NavigationLink(CartoucheText.telemetryLastReport) {
                        CartoucheTelemetryReportView(json: report)
                    }
                }
            } footer: {
                if CartoucheTelemetry.endpoint == nil {
                    Text(CartoucheText.telemetryNoServer)
                }
            }
            Section {
                Button(CartoucheText.telemetryErase, role: .destructive) {
                    confirmingErase = true
                }
                .disabled(telemetry.isErasing)
                Link(destination: CartoucheTelemetry.privacyURL) {
                    Label(CartoucheText.telemetryPrivacy, systemImage: "lock.shield")
                }
            } footer: {
                if eraseFailed {
                    Text(CartoucheText.telemetryEraseFailed)
                        .foregroundStyle(.red)
                }
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(CartoucheText.telemetryTitle)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(CartoucheText.telemetryErase, isPresented: $confirmingErase, titleVisibility: .visible) {
            Button(CartoucheText.telemetryEraseConfirm, role: .destructive) {
                Task { eraseFailed = !(await telemetry.erase()) }
            }
        } message: {
            Text(CartoucheText.telemetryEraseMessage)
        }
    }
}

/// A report as it left the iPhone, its keys one per line.
@available(iOS 17.0, *)
struct CartoucheTelemetryReportView: View {
    let json: String

    private var text: String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return json
        }
        return String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .cartoucheStageBackground()
        .navigationTitle(CartoucheText.telemetryLastReport)
        .navigationBarTitleDisplayMode(.inline)
    }
}
