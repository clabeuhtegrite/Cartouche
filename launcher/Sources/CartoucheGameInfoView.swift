//
//  CartoucheGameInfoView.swift
//  Cartouche
//
//  What the player says of one of their games, from its sheet: its name,
//  its platform, its genre, its summary and its cover, chosen in Photos or
//  in Files, over what Cartouche finds by itself (CartouchePlayerInfo). The
//  summary starts as IGDB's, for the player to change or replace. The cover
//  shows as it will on the console while the player chooses it. Cancel
//  leaves the game as it was; Save keeps what the page says, on this iPhone
//  only. For a game Cartouche does not know, the page says what IGDB has
//  of it by its name (CartoucheGameLookup): a new name is looked up again.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@available(iOS 17.0, *)
struct CartoucheGameInfoView: View {
    let entry: CartoucheEntry
    /// Closes the page.
    let onClose: () -> Void

    /// The cover the game shows.
    private enum Cover: Equatable {
        /// The one the player chose before.
        case kept
        /// Cartouche's own: IGDB's, or its drawing.
        case automatic
        /// One the player has just chosen, as Cartouche keeps it: a JPEG in
        /// a temporary file, until the page is saved.
        case new(URL)
    }

    @State private var name: String
    @State private var platform: String
    @State private var genre: String
    @State private var summary: String
    @State private var cover: Cover
    @State private var photo: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var choosingFile = false
    @State private var isReading = false
    @State private var problem: String?

    // Written out: the private state above would make the synthesized
    // initializer private.
    init(entry: CartoucheEntry, onClose: @escaping () -> Void) {
        self.entry = entry
        self.onClose = onClose
        _name = State(initialValue: entry.name)
        _platform = State(initialValue: entry.player?.platform ?? "")
        _genre = State(initialValue: entry.player?.genre ?? "")
        _summary = State(initialValue: entry.summary ?? "")
        _cover = State(initialValue: entry.playerCover != nil ? .kept : .automatic)
    }

    /// Cartouche's genres, by their names.
    private static var genres: [String] {
        CartoucheCoverList.genres.sorted {
            (CartoucheText.genre($0) ?? $0).localizedStandardCompare(CartoucheText.genre($1) ?? $1) == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section {
                coverRow
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                }
            }

            Section {
                TextField(entry.ownName, text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
            } header: {
                Text(CartoucheText.gameInfoName)
            } footer: {
                if entry.isUnknown {
                    Text(entry.found.map { CartoucheText.gameInfoFound($0.name) } ?? CartoucheText.gameInfoNotFound)
                }
            }

            Section {
                Picker(CartoucheText.gameInfoPlatform, selection: $platform) {
                    Text(CartoucheText.gameInfoAutomatic(entry.ownPlatform.map(CartoucheText.platform))).tag("")
                    ForEach(["switch", "switch2"], id: \.self) { choice in
                        Text(CartoucheText.platform(choice)).tag(choice)
                    }
                }
                Picker(CartoucheText.gameInfoGenre, selection: $genre) {
                    Text(CartoucheText.gameInfoAutomatic(entry.ownGenre.flatMap(CartoucheText.genre))).tag("")
                    ForEach(Self.genres, id: \.self) { choice in
                        Label(CartoucheText.genre(choice) ?? choice, systemImage: CartoucheTheme.symbol(genre: choice)).tag(choice)
                    }
                }
            } footer: {
                Text(CartoucheText.gameInfoFooter)
            }

            Section {
                TextField(CartoucheText.gameInfoSummaryPrompt, text: $summary, axis: .vertical)
                    .lineLimit(4 ... 12)
            } header: {
                Text(CartoucheText.gameInfoSummary)
            } footer: {
                if entry.ownSummary != nil {
                    Text(CartoucheText.gameInfoSummaryFooter)
                }
            }

            if entry.player != nil {
                Section {
                    Button(role: .destructive) {
                        name = entry.ownName
                        platform = ""
                        genre = ""
                        summary = entry.ownSummary ?? ""
                        useCartouchesCover()
                    } label: {
                        Label(CartoucheText.gameInfoReset, systemImage: "arrow.uturn.backward")
                            .foregroundStyle(CartoucheTheme.danger)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CartoucheStage(key: entry.tileKey, art: shown.backdrop))
        .navigationTitle(CartoucheText.gameInfoTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A symbol as well as a name: the iPhone Duo shows the bars of a
            // sheet down the side of its outer display, where an item with a
            // name alone does not appear.
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    forgetNewCover()
                    onClose()
                } label: {
                    Label(CartoucheText.cancel, systemImage: "xmark")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    Label(CartoucheText.gameInfoSave, systemImage: "checkmark")
                }
                .disabled(isReading)
            }
        }
        // B cancels, as Cancel does, once every view has had the input:
        // the sheet under the page, which waits for it to close, does not
        // take it too. Not while Photos or Files is open over the page.
        .onReceive(CartoucheGamepad.shared.inputs) { input in
            guard input == .b, !choosingPhoto, !choosingFile else { return }
            DispatchQueue.main.async {
                forgetNewCover()
                onClose()
            }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            isReading = true
            Task {
                await take(try? await item.loadTransferable(type: Data.self))
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            isReading = true
            Task {
                let data = await Task.detached { () -> Data? in
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                }.value
                await take(data)
            }
        }
    }

    // MARK: The cover

    /// The game as the console will show it, with what the page says.
    private var shown: CartoucheEntry {
        var shown = entry
        var info = shown.player ?? CartouchePlayerInfo()
        info.name = typedName
        info.platform = platform.isEmpty ? nil : platform
        info.genre = genre.isEmpty ? nil : genre
        info.summary = typedSummary
        shown.player = info
        switch cover {
        case .kept: break
        case .automatic: shown.playerCover = nil
        case .new(let file): shown.playerCover = file
        }
        return shown
    }

    /// Whether Cartouche has a cover of the game of its own.
    private var hasCartouchesCover: Bool {
        entry.cover != nil || entry.found != nil
    }

    private var coverRow: some View {
        HStack(alignment: .center, spacing: 18) {
            CartoucheGameCartridge(entry: shown, width: 92)
                .overlay {
                    if isReading {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.white)
                    }
                }
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    choosingPhoto = true
                } label: {
                    Label(CartoucheText.gameInfoCoverPhotos, systemImage: "photo.on.rectangle")
                }
                Button {
                    choosingFile = true
                } label: {
                    Label(CartoucheText.gameInfoCoverFile, systemImage: "folder")
                }
                if cover != .automatic {
                    Button(role: .destructive) {
                        useCartouchesCover()
                    } label: {
                        Label(hasCartouchesCover ? CartoucheText.gameInfoCoverOfficial : CartoucheText.gameInfoCoverRemove,
                              systemImage: "arrow.uturn.backward")
                            .foregroundStyle(CartoucheTheme.danger)
                    }
                }
            }
            // Each button on its own: a row of a form is otherwise one
            // button for all of them.
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
            // A name on two lines starts where its symbol ends.
            .multilineTextAlignment(.leading)
            .disabled(isReading)
        }
    }

    /// DATA, the image the player chose, as the game's cover, made as
    /// Cartouche keeps it away from the screen's work; a note when it is no
    /// image.
    private func take(_ data: Data?) async {
        defer { isReading = false }
        let jpeg: Data? = await Task.detached {
            data.flatMap { CartouchePlayerInfoStore.jpeg(from: $0) }
        }.value
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Cover-\(UUID().uuidString).jpg")
        guard let jpeg, (try? jpeg.write(to: file, options: .atomic)) != nil else {
            problem = CartoucheText.gameInfoCoverUnreadable
            return
        }
        forgetNewCover()
        cover = .new(file)
        problem = nil
    }

    private func useCartouchesCover() {
        forgetNewCover()
        cover = .automatic
        problem = nil
    }

    /// Removes the temporary file of a cover just chosen.
    private func forgetNewCover() {
        if case .new(let file) = cover { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: Saving

    /// The name typed, or nil for the game's own.
    private var typedName: String? {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty || typed == entry.ownName ? nil : typed
    }

    /// The summary written, or nil for IGDB's.
    private var typedSummary: String? {
        guard let typed = CartoucheCoverList.summary(summary) else { return nil }
        return typed == entry.ownSummary ? nil : typed
    }

    private func save() {
        var info = CartouchePlayerInfo(name: typedName, platform: platform.isEmpty ? nil : platform,
                                       genre: genre.isEmpty ? nil : genre)
        info.summary = typedSummary
        var data: Data?
        switch cover {
        case .kept:
            info.cover = entry.player?.cover
        case .automatic:
            break
        case .new(let file):
            data = try? Data(contentsOf: file)
            guard data != nil else {
                problem = CartoucheText.gameInfoCoverUnreadable
                return
            }
        }
        do {
            try CartoucheCatalog.shared.setPlayerInfo(info, cover: data, for: entry)
        } catch {
            problem = CartoucheText.gameInfoNotSaved(error.localizedDescription)
            return
        }
        // What the player changed, never what they wrote or chose.
        CartoucheTelemetry.shared.event("game.infoChanged", game: entry.titleId, fields: [
            "known": .flag(!entry.isUnknown), "found": .flag(entry.found != nil), "name": .flag(info.name != nil),
            "platform": .flag(info.platform != nil), "genre": .flag(info.genre != nil),
            "summary": .flag(info.summary != nil), "cover": .flag(data != nil || info.cover != nil),
        ])
        forgetNewCover()
        onClose()
    }
}
