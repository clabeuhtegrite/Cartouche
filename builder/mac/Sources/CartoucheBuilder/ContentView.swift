//
//  ContentView.swift
//  Cartouche Builder
//
//  The window: its pages in a sidebar, the page chosen, a message above
//  it when something went wrong, and the setup assistant.
//

import BuilderKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var setup: MacSetup
    @EnvironmentObject private var bridge: BridgeController

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    BannerView(banner: banner) { model.banner = nil }
                        .padding([.horizontal, .top], 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.snappy, value: model.banner)
        }
        .sheet(isPresented: $model.showSetup) {
            SetupAssistant(start: model.setupStep)
                .environmentObject(model)
                .environmentObject(setup)
                .environmentObject(bridge)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .library: LibraryView()
        case .activity: ActivityView()
        case .storage: StorageView()
        case .iphone: BridgeView()
        case .setup: SetupView()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var setup: MacSetup
    @EnvironmentObject private var bridge: BridgeController

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
            ForEach(AppSection.allCases) { section in
                row(section)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            EngineFooter()
                .padding(12)
        }
    }

    @ViewBuilder private func row(_ section: AppSection) -> some View {
        switch section {
        case .library:
            Label(section.title, systemImage: section.symbol)
                .badge(model.library?.due.count ?? 0)
        case .activity:
            Label(section.title, systemImage: model.isBuilding ? "hammer.fill" : section.symbol)
                .badge(model.isBuilding ? Text(model.status?.current.first.flatMap { ($0.overall ?? $0.frac).map(Format.percent) } ?? "…") : nil)
        case .storage:
            Label(section.title, systemImage: section.symbol)
        case .iphone:
            Label(section.title, systemImage: section.symbol)
                .badge(bridge.connected.isEmpty ? nil : Text("\(bridge.connected.count)"))
        case .setup:
            Label(section.title, systemImage: setup.ready ? section.symbol : "exclamationmark.triangle")
                .badge(setup.ready ? 0 : setup.missingCount)
        }
    }
}

/// nxnative's version and when it was checked, under the pages.
struct EngineFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                Text(model.library?.engine.map { "nxnative \($0.short.prefix(8))" } ?? "nxnative")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if model.checking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await model.refreshLibrary(update: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(tr("Check nxnative now", "Vérifier nxnative maintenant"))
                    .disabled(model.engine == nil)
                }
            }
            Text(checkedText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    private var checkedText: String {
        if model.checking { return tr("Checking nxnative…", "Vérification de nxnative…") }
        guard let checked = model.library?.checked.flatMap(ISODate.parse) else { return tr("Not checked yet", "Pas encore vérifié") }
        return tr("Checked ", "Vérifié ") + Format.relative(checked)
    }
}

struct BannerView: View {
    let banner: Banner
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.kind == .error ? Color.orange : Theme.indigo)
            Text(banner.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((banner.kind == .error ? Color.orange : Theme.indigo).opacity(0.12))
        )
    }
}
