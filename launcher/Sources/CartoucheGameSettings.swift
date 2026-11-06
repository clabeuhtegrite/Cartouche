//
//  CartoucheGameSettings.swift
//  Cartouche
//
//  A game's own settings in Cartouche: the rows nxnative's settings screen
//  shows before the game (its Launcher.swift and LauncherSettings.swift),
//  read from the game's dm/launcher.json, in the reader's language. The
//  choices go where nxnative keeps them, in the game's preferences
//  ("launcher.<variable>", only a choice that differs from the game's
//  default; "cloudSavesBookmark" for the cloud saves folder), which
//  CartoucheGameActions.settings(for:tileKey:) opens. Play starts the game
//  with them, without that screen (DM_LAUNCHER=0: nxnative applies the
//  saved choices), and the game's in-game menu changes the same ones. A
//  setting an env file sets wins over a choice (nxnative's main.m): it
//  shows, but does not change here.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One row of nxnative's settings screen, as dm/launcher.json lists it
/// (nxnative's LauncherSettings.swift, Setting).
struct CartoucheGameSetting: Decodable, Identifiable, Hashable {
    struct Base: Decodable, Hashable {
        let docked: [Int]
        let handheld: [Int]
    }

    let env: String
    /// choice, range or toggle.
    let kind: String
    let label: String
    let note: String
    let def: String
    let section: String?
    /// "<variable>=<value>": shown only while that setting has that value.
    let needs: String?
    /// The render scale's 3D size at 1.0, docked and handheld.
    let base: Base?
    /// A choice's [value, label] pairs.
    let options: [[String]]?
    let min: Double?
    let max: Double?
    let step: Double?
    /// A toggle's two values, 1 and 0 when not given.
    let on: String?
    let off: String?

    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    /// A choice's options that have a value and a label.
    var choices: [[String]] { (options ?? []).filter { $0.count >= 2 } }

    /// A range compares as numbers: a slider writes 1.00 for 1.0.
    func isDefault(_ value: String) -> Bool {
        kind == "range" ? abs((Double(value) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : value == def
    }

    /// Whether the game still offers a saved choice.
    func accepts(_ value: String) -> Bool {
        switch kind {
        case "choice":
            return choices.contains { $0[0] == value }
        case "range":
            guard !value.contains(where: { $0 == "x" || $0 == "X" }), let number = Double(value), number.isFinite,
                  let low = min, let high = max else { return false }
            return number >= low && number <= high
        case "toggle":
            return value == onValue || value == offValue
        default:
            return true
        }
    }

    enum CodingKeys: String, CodingKey {
        case env, kind, label, note, def = "default", section, needs, base, options, min, max, step, on, off
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        env = try values.decode(String.self, forKey: .env)
        kind = try values.decode(String.self, forKey: .kind)
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? env
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        def = try values.decode(String.self, forKey: .def)
        section = try values.decodeIfPresent(String.self, forKey: .section)
        needs = try values.decodeIfPresent(String.self, forKey: .needs)
        base = try? values.decodeIfPresent(Base.self, forKey: .base)
        options = try values.decodeIfPresent([[String]].self, forKey: .options)
        min = try values.decodeIfPresent(Double.self, forKey: .min)
        max = try values.decodeIfPresent(Double.self, forKey: .max)
        step = try values.decodeIfPresent(Double.self, forKey: .step)
        on = try values.decodeIfPresent(String.self, forKey: .on)
        off = try values.decodeIfPresent(String.self, forKey: .off)
    }

    /// The rows of a settings list such as dm/launcher.json.
    static func rows(in data: Data) -> [CartoucheGameSetting]? {
        struct File: Decodable { let settings: [CartoucheGameSetting] }
        return (try? JSONDecoder().decode(File.self, from: data))?.settings
    }

    /// The rows of a game's dm/launcher.json; a game of several programs
    /// keeps the first program's in dm/p0.
    static func rows(inBundle bundle: URL) -> [CartoucheGameSetting]? {
        let dm = bundle.appendingPathComponent("dm", isDirectory: true)
        for file in [dm.appendingPathComponent("launcher.json"), dm.appendingPathComponent("p0/launcher.json")] {
            if let data = try? Data(contentsOf: file), let rows = rows(in: data) {
                return rows
            }
        }
        return nil
    }

    /// The variables an env file sets (Documents/env.txt, then the bundle's
    /// dm/env.txt), which nxnative keeps over the player's choices.
    static func fixedValues(home: URL?, bundle: URL) -> [String: String] {
        var found: [String: String] = [:]
        let files = [home?.appendingPathComponent("Documents/env.txt"), bundle.appendingPathComponent("dm/env.txt")]
        for file in files.compactMap({ $0 }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let equal = line.firstIndex(of: "="), equal != line.startIndex else { continue }
                let key = String(line[..<equal])
                if found[key] == nil { found[key] = String(line[line.index(after: equal)...]) }
            }
        }
        return found
    }
}

/// Where a game keeps the player's choices: its preferences.
protocol CartoucheGameChoices: AnyObject {
    /// A string only, as nxnative reads a choice: never a number turned
    /// into one.
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    /// nil removes the key.
    func set(_ value: Any?, forKey key: String)
}

/// A game's settings and the player's choices, as nxnative's LauncherModel
/// keeps them.
@MainActor
final class CartoucheGameSettingsModel: ObservableObject, Hashable {
    let name: String
    let tileKey: String
    let settings: [CartoucheGameSetting]
    /// Set by an env file: shown, not changed.
    let fixed: [String: String]
    /// nil when Cartouche cannot reach the game's preferences.
    private let choices: CartoucheGameChoices?
    @Published private(set) var values: [String: String] = [:]
    @Published private(set) var cloudFolder: String?
    @Published private(set) var cloudNote: String?

    static let cloudKey = "cloudSavesBookmark"

    init(name: String, tileKey: String, settings: [CartoucheGameSetting], fixed: [String: String], choices: CartoucheGameChoices?) {
        self.name = name
        self.tileKey = tileKey
        self.settings = settings
        self.fixed = fixed
        self.choices = choices
        for setting in settings {
            if let value = fixed[setting.env] {
                values[setting.env] = value
                continue
            }
            // A saved choice the game no longer offers: its default.
            let saved = choices?.string(forKey: "launcher." + setting.env)
            values[setting.env] = saved.flatMap { setting.accepts($0) ? $0 : nil } ?? setting.def
        }
        readCloudFolder()
    }

    nonisolated static func == (lhs: CartoucheGameSettingsModel, rhs: CartoucheGameSettingsModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    var canChange: Bool { choices != nil }

    func value(_ setting: CartoucheGameSetting) -> String {
        values[setting.env] ?? setting.def
    }

    func isFixed(_ setting: CartoucheGameSetting) -> Bool {
        fixed[setting.env] != nil
    }

    /// Saved at once, as nxnative's Play saves it: a default leaves no choice.
    func choose(_ setting: CartoucheGameSetting, _ value: String) {
        guard let choices, !isFixed(setting), setting.accepts(value), values[setting.env] != value else { return }
        values[setting.env] = value
        choices.set(setting.isDefault(value) ? nil : value, forKey: "launcher." + setting.env)
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }

    /// A sub-setting shows only while the setting it needs has that value.
    func visible(_ setting: CartoucheGameSetting) -> Bool {
        guard let needs = setting.needs, let equal = needs.firstIndex(of: "=") else { return true }
        let key = String(needs[..<equal])
        guard let current = values[key] else { return true }
        return current == String(needs[needs.index(after: equal)...])
    }

    func rows(in section: String) -> [CartoucheGameSetting] {
        settings.filter { $0.sectionTitle == section && visible($0) }
    }

    // MARK: Categories

    /// The cloud saves, the page's last category after nxnative's sections.
    static let savesCategory = "cartouche.saves"

    /// The category the player picked; nil for the first.
    @Published var category: String?

    var categories: [String] {
        sections.filter { !rows(in: $0).isEmpty } + (canChange ? [Self.savesCategory] : [])
    }

    /// The category on screen: the one picked, else the first.
    var currentCategory: String? {
        let all = categories
        if let category, all.contains(category) { return category }
        return all.first
    }

    /// The previous or the next category, as L and R move between them.
    func moveCategory(by step: Int) {
        let all = categories
        guard !all.isEmpty else { return }
        let index = currentCategory.flatMap { all.firstIndex(of: $0) } ?? 0
        category = all[min(max(index + step, 0), all.count - 1)]
    }

    /// An end of a range, as a percentage.
    static func rangeBound(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// A range: its percentage, and the 3D size in pixels for the console
    /// mode chosen when the list gives it.
    func rangeLabel(_ setting: CartoucheGameSetting, _ value: Double) -> String {
        let percent = value.formatted(.percent.precision(.fractionLength(0)))
        guard let base = setting.base else { return percent }
        let size = (values["DM_OPMODE"] ?? "1") == "0" ? base.handheld : base.docked
        guard size.count == 2 else { return percent }
        return "\(Int((Double(size[0]) * value).rounded())) × \(Int((Double(size[1]) * value).rounded())) (\(percent))"
    }

    var changed: Bool {
        settings.contains { !isFixed($0) && !$0.isDefault(value($0)) }
    }

    /// Every choice back to the settings the game was tested with.
    func reset() {
        guard let choices else { return }
        for setting in settings where !isFixed(setting) {
            values[setting.env] = setting.def
            choices.set(nil, forKey: "launcher." + setting.env)
        }
    }

    // MARK: Cloud saves

    /// The folder the game brings its save in from and sends it to, kept as
    /// a bookmark the game resolves (nxnative's CloudSaves.m). Cartouche is
    /// the same app as the game it starts, so the game resolves it too.
    private func readCloudFolder() {
        cloudFolder = nil
        guard let bookmark = choices?.data(forKey: Self.cloudKey), !bookmark.isEmpty else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            cloudFolder = url.lastPathComponent
        } else {
            cloudNote = CartoucheText.cloudStale
        }
    }

    func chooseCloudFolder(_ url: URL) {
        guard let choices else { return }
        // Written while the picker's access is held: a bookmark written
        // without it resolves to nothing from the next start on.
        let accessing = url.startAccessingSecurityScopedResource()
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        if accessing { url.stopAccessingSecurityScopedResource() }
        var stale = false
        guard let bookmark,
              (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)) != nil else {
            cloudNote = CartoucheText.cloudFailed
            return
        }
        choices.set(bookmark, forKey: Self.cloudKey)
        readCloudFolder()
        cloudNote = CartoucheText.cloudSaved
    }

    func turnOffCloudSaves() {
        choices?.set(nil, forKey: Self.cloudKey)
        cloudNote = nil
        readCloudFolder()
    }
}

/// The game's settings page, from its sheet.
@available(iOS 17.0, *)
struct CartoucheGameSettingsView: View {
    @ObservedObject var model: CartoucheGameSettingsModel
    /// Starts the game on nxnative's own settings screen.
    let onNxnativeScreen: () -> Void
    @State private var choosingFolder = false

    // Written out: before Swift 6.4 (SE-0502), the private state above made
    // the synthesized initializer private.
    init(model: CartoucheGameSettingsModel, onNxnativeScreen: @escaping () -> Void) {
        self.model = model
        self.onNxnativeScreen = onNxnativeScreen
    }

    var body: some View {
        List {
            Section {
                if model.settings.isEmpty {
                    Text(CartoucheText.settingsNone)
                } else if !model.canChange {
                    Label(CartoucheText.settingsUnreachable, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                } else {
                    Text(CartoucheText.settingsIntro)
                }
            }
            .foregroundStyle(CartoucheTheme.secondaryText)
            .font(.subheadline)
            .listRowBackground(Color.clear)

            if model.categories.count > 1 {
                Section {
                    CartoucheSettingsCategoryBar(model: model)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if let category = model.currentCategory {
                if category == CartoucheGameSettingsModel.savesCategory {
                    cloudSaves
                } else {
                    Section {
                        ForEach(model.rows(in: category)) { setting in
                            CartoucheGameSettingRow(setting: setting, model: model)
                        }
                    } header: {
                        // The bar names the category when there is one.
                        if model.categories.count <= 1 {
                            Text(CartoucheText.gameSettingText(category))
                        }
                    }
                }
            }
            if model.canChange {
                if !model.settings.isEmpty {
                    Section {
                        Button(CartoucheText.settingsReset) { model.reset() }
                            .disabled(!model.changed)
                    } footer: {
                        Text(CartoucheText.settingsResetFooter)
                    }
                }
            }
            if !model.settings.isEmpty {
                Section {
                    Button(CartoucheText.settingsNxnativeScreen, action: onNxnativeScreen)
                } footer: {
                    Text(CartoucheText.settingsNxnativeScreenFooter)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CartoucheStage(key: model.tileKey))
        .navigationTitle(CartoucheText.gameSettings)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $choosingFolder) {
            CartoucheFolderPicker { url in
                choosingFolder = false
                if let url { model.chooseCloudFolder(url) }
            }
            .ignoresSafeArea()
        }
    }

    private var cloudSaves: some View {
        Section {
            LabeledContent(CartoucheText.cloudTitle) {
                Text(model.cloudFolder ?? CartoucheText.cloudOff)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button(model.cloudFolder == nil ? CartoucheText.cloudChoose : CartoucheText.cloudChange) {
                choosingFolder = true
            }
            if model.cloudFolder != nil {
                Button(CartoucheText.cloudTurnOff, role: .destructive) { model.turnOffCloudSaves() }
            }
        } footer: {
            Text(model.cloudNote ?? CartoucheText.cloudFooter)
        }
    }
}

/// One setting: a menu, a slider with its value, or a switch.
@available(iOS 17.0, *)
struct CartoucheGameSettingRow: View {
    let setting: CartoucheGameSetting
    @ObservedObject var model: CartoucheGameSettingsModel

    private var note: String {
        let note = CartoucheText.gameSettingText(setting.note)
        guard model.isFixed(setting) else { return note }
        return note.isEmpty ? CartoucheText.settingFixed : note + " · " + CartoucheText.settingFixed
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CartoucheText.gameSettingText(setting.label))
            if !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(CartoucheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// An option's name; a language's, from its code, in the reader's
    /// language (nxnative lists the game's languages by code).
    private func optionName(_ option: [String]) -> String {
        setting.env == "DM_LANG" ? CartoucheText.languageName(option[0], english: option[1])
            : CartoucheText.gameSettingText(option[1])
    }

    private var choice: Binding<String> {
        Binding(get: { model.value(setting) }, set: { model.choose(setting, $0) })
    }

    private var range: Binding<Double> {
        Binding(get: { Double(model.value(setting)) ?? setting.max ?? 1 },
                set: { model.choose(setting, String(format: "%.2f", $0)) })
    }

    var body: some View {
        Group {
            switch setting.kind {
            case "choice":
                Picker(selection: choice) {
                    ForEach(setting.choices, id: \.self) { option in
                        Text(optionName(option)).tag(option[0])
                    }
                } label: {
                    label
                }
                .pickerStyle(.menu)
            case "range":
                let low = setting.min ?? 0
                let high = Swift.max(setting.max ?? 1, low)
                VStack(alignment: .leading, spacing: 6) {
                    label
                    Slider(value: range, in: low...high, step: setting.step ?? 0.05)
                        .accessibilityLabel(CartoucheText.gameSettingText(setting.label))
                        .accessibilityValue(model.rangeLabel(setting, range.wrappedValue))
                    // The value, large, between the ends of the range.
                    HStack(alignment: .firstTextBaseline) {
                        Text(CartoucheGameSettingsModel.rangeBound(low))
                        Spacer(minLength: 8)
                        Text(model.rangeLabel(setting, range.wrappedValue))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                        Spacer(minLength: 8)
                        Text(CartoucheGameSettingsModel.rangeBound(high))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(CartoucheTheme.tertiaryText)
                    .accessibilityHidden(true)
                }
            default:
                Toggle(isOn: Binding(get: { model.value(setting) == setting.onValue },
                                     set: { model.choose(setting, $0 ? setting.onValue : setting.offValue) })) {
                    label
                }
            }
        }
        .disabled(model.isFixed(setting) || !model.canChange)
    }
}

/// The page's categories, as buttons in a row: one shows at a time, and L
/// and R move between them.
@available(iOS 17.0, *)
struct CartoucheSettingsCategoryBar: View {
    @ObservedObject var model: CartoucheGameSettingsModel

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(model.categories, id: \.self) { category in
                        button(category, selected: category == model.currentCategory)
                            .id(category)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.currentCategory) { _, category in
                guard let category else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    reader.scrollTo(category, anchor: .center)
                }
            }
        }
    }

    private func button(_ category: String, selected: Bool) -> some View {
        Button {
            model.category = category
        } label: {
            VStack(spacing: 6) {
                Image(systemName: Self.symbol(category))
                    .font(.system(size: 17, weight: selected ? .semibold : .regular))
                Text(Self.title(category))
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.white : CartoucheTheme.secondaryText)
            .padding(.horizontal, 12)
            .frame(minWidth: 78, minHeight: 58)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? CartoucheTheme.indigo.opacity(0.5) : Color.white.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(selected ? 0.35 : 0.08), lineWidth: 1))
            .animation(.bouncy(duration: 0.3), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func symbol(_ category: String) -> String {
        switch category {
        case CartoucheGameSettingsModel.savesCategory: return "icloud.fill"
        case "Game": return "gamecontroller.fill"
        case "Controls": return "dpad.fill"
        case "Performance": return "speedometer"
        default: return "slider.horizontal.3"
        }
    }

    static func title(_ category: String) -> String {
        category == CartoucheGameSettingsModel.savesCategory ? CartoucheText.settingsSaves
            : CartoucheText.gameSettingText(category)
    }
}

/// The Files picker for a folder, which stays where it is: the game keeps
/// a bookmark to it.
struct CartoucheFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void

        init(onPick: @escaping (URL?) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
