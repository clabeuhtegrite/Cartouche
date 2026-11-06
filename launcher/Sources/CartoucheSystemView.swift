//
//  CartoucheSystemView.swift
//  Cartouche
//
//  What Cartouche has on this iPhone: the memory limit iOS sets for it,
//  which its games share; when its signature expires; and the device that
//  the game sheets are compared with.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheSystemView: View {
    @State private var memory = CartoucheMemoryReading.now()
    @State private var signature = CartoucheSignature.current()

    private let catalog = CartoucheCatalog.shared

    var body: some View {
        NavigationStack {
            List {
                memorySection
                signatureSection
                deviceSection
                cartoucheSection
            }
            .navigationTitle(CartoucheText.systemTab)
            .refreshable { measure() }
        }
        .onAppear(perform: measure)
    }

    private func measure() {
        memory = CartoucheMemoryReading.now()
        signature = CartoucheSignature.current()
    }

    // MARK: Memory

    private var memorySection: some View {
        Section {
            if let memory {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(CartoucheText.memoryLimit, value: CartoucheText.memoryAmount(mebibytes: memory.limitMiB))
                        .font(.headline)
                    Gauge(value: Double(memory.footprintBytes), in: 0...Double(max(memory.limitBytes, 1))) {
                        Text(CartoucheText.memoryUsed)
                    }
                    .gaugeStyle(.linearCapacity)
                    .labelsHidden()
                }
                .padding(.vertical, 4)
                LabeledContent(CartoucheText.memoryUsed, value: CartoucheText.memoryAmount(mebibytes: memory.footprintMiB))
                LabeledContent(CartoucheText.memoryAvailable, value: CartoucheText.memoryAmount(mebibytes: memory.availableMiB))
            } else {
                Text(CartoucheText.memoryUnavailable)
                    .foregroundStyle(.secondary)
            }
            LabeledContent(CartoucheText.imlRequirement) {
                let active = CartoucheDevice.hasIncreasedMemoryLimit
                Label(active ? CartoucheText.imlOn : CartoucheText.imlOff,
                      systemImage: active ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(active ? Color.green : Color.orange)
            }
            Button(CartoucheText.measureAgain, systemImage: "arrow.clockwise", action: measure)
        } header: {
            Text(CartoucheText.memory)
        } footer: {
            Text(memoryFooter)
        }
    }

    private var memoryFooter: String {
        var text = CartoucheText.memoryFooter
        if let known = knownLimitMiB {
            text += " " + CartoucheText.memoryKnown(CartoucheText.memoryAmount(mebibytes: known))
        }
        return text
    }

    /// The latest limit testers measured on this model with the capability.
    private var knownLimitMiB: Int? {
        catalog.device(CartoucheDevice.modelIdentifier)?.measurements
            .filter(\.increasedMemoryLimit)
            .max { $0.date < $1.date }?
            .appMemoryLimitMiB
    }

    // MARK: Signature

    private var signatureSection: some View {
        Section {
            if let expirationDate = signature.expirationDate, let daysLeft = signature.daysLeft {
                LabeledContent(CartoucheText.expires, value: expirationDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent(CartoucheText.daysLeft) {
                    Text(daysLeft < 0 ? CartoucheText.expired : String(daysLeft))
                        .foregroundStyle(daysLeft < 0 ? Color.red : daysLeft <= 2 ? Color.orange : Color.secondary)
                        .fontWeight(daysLeft <= 2 ? .semibold : .regular)
                }
            } else {
                Text(CartoucheText.profileUnknown)
                    .foregroundStyle(.secondary)
            }
            if let renewalDate = signature.renewalDate {
                LabeledContent(CartoucheText.renewed, value: renewalDate.formatted(date: .abbreviated, time: .shortened))
            }
            if let teamName = signature.teamName {
                LabeledContent(CartoucheText.team, value: teamName)
            }
            if UserDefaults.sideStoreExist() {
                Button(CartoucheText.openSideStore, systemImage: "arrow.triangle.2.circlepath") {
                    LCUtils.openSideStore()
                }
            }
        } header: {
            Text(CartoucheText.signature)
        } footer: {
            Text(CartoucheText.signatureFooter)
        }
    }

    // MARK: This iPhone

    private var deviceSection: some View {
        let device = catalog.device(CartoucheDevice.modelIdentifier)
        return Section(CartoucheText.thisIPhone) {
            LabeledContent(CartoucheText.model, value: CartoucheDevice.modelIdentifier)
            if let device {
                LabeledContent(CartoucheText.chip, value: device.chip)
                LabeledContent(CartoucheText.ram, value: CartoucheText.gigabytes(device.memoryGB))
            } else {
                LabeledContent(CartoucheText.ram, value: CartoucheText.memoryAmount(
                    mebibytes: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)))
            }
            LabeledContent("iOS", value: CartoucheDevice.iOSVersion)
            LabeledContent(CartoucheText.bcRequirement,
                           value: CartoucheDevice.supportsBCTextureCompression ? CartoucheText.gpuSupported : CartoucheText.gpuUnsupported)
        }
    }

    // MARK: Cartouche

    private var cartoucheSection: some View {
        Section("Cartouche") {
            LabeledContent(CartoucheText.version, value: version)
            LabeledContent(CartoucheText.sheets, value: String(catalog.sheets.count))
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        var text = info?["CFBundleShortVersionString"] as? String ?? "?"
        if let build = info?["LCVersionInfo"] as? String, !build.isEmpty {
            text += " (" + build + ")"
        }
        return text
    }
}
