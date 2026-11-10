//
//  CartoucheStorageView.swift
//  Cartouche
//
//  The player's storage, on screen: the System page's Storage page, where
//  the player signs in to a shared folder of their Mac, PC or NAS, or picks
//  a folder in Files, and chooses the games folder and the saves folder;
//  and, on a game's sheet, the copies of its saves, which can be put back.
//

import Combine
import Network
import SwiftUI

// MARK: Storage page

@available(iOS 17.0, *)
struct CartoucheStorageView: View {
    @ObservedObject private var settings = CartoucheStorageSettings.shared
    @ObservedObject private var stored = CartoucheStoredGames.shared
    @ObservedObject private var backups = CartoucheSaveBackups.shared
    @ObservedObject private var reach = CartoucheStorageReach.shared
    @State private var editing: CartoucheStorageServer?
    @State private var browsing: Browsing?
    @State private var choosingFolder = false

    /// A server whose folders the player is looking through, for a role.
    struct Browsing: Identifiable {
        let server: CartoucheStorageServer
        let role: CartoucheStorageRole
        var id: String { server.id.uuidString + "|" + role.rawValue }
    }

    // Written out: before Swift 6.4 (SE-0502), the private state above made
    // the synthesized initializer private.
    init() {}

    var body: some View {
        List {
            Section {
                Text(CartoucheText.storageIntro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            placeSection(.games)
            placeSection(.saves)
            serversSection
        }
        .cartoucheStageBackground()
        .navigationTitle(CartoucheText.storageTitle)
        .sheet(item: $editing) { server in
            NavigationStack {
                if server.kind == .mac {
                    CartoucheStorageMacForm(server: server)
                } else if server.kind == .s3 {
                    CartoucheStorageS3Form(server: server)
                } else if server.kind == .ftp || server.kind == .sftp {
                    CartoucheStorageFTPForm(server: server)
                } else {
                    CartoucheStorageServerForm(server: server)
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $browsing) { browsing in
            NavigationStack {
                CartoucheStorageFolderBrowser(server: browsing.server, path: "", role: browsing.role) { path in
                    settings.setPlace(CartoucheStoragePlace(server: browsing.server.id, path: path), for: browsing.role)
                    self.browsing = nil
                    if browsing.role == .games { stored.refresh() }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(CartoucheText.cancel) { self.browsing = nil }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $choosingFolder) {
            CartoucheFolderPicker { url in
                choosingFolder = false
                if let url { addFolder(url) }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: The games folder and the saves folder

    private func placeSection(_ role: CartoucheStorageRole) -> some View {
        Section {
            if let place = settings.place(role), let server = settings.server(place.server) {
                LabeledContent {
                    Text(Self.placeName(server: server, path: place.path))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label(Self.title(role), systemImage: Self.symbol(role))
                }
                // A server that does not answer from here, as a NAS away
                // from home: the games folder keeps its last list and the
                // saves wait, until it answers again.
                let offline = reach.isOffline(server.id)
                if role == .games {
                    LabeledContent(CartoucheText.storageGamesFound) {
                        if stored.isScanning {
                            ProgressView()
                        } else {
                            Text(verbatim: "\(stored.games.count)")
                        }
                    }
                    if offline {
                        Label(CartoucheStorageOffline(server).localizedDescription, systemImage: "wifi.slash")
                            .font(.footnote)
                            .foregroundStyle(Color.orange)
                    } else if let problem = stored.problemReport {
                        Text(problem.message)
                            .font(.footnote)
                            .foregroundStyle(Color.orange)
                        CartoucheReportButton(report: problem)
                    } else if settings.isReadOnly(.games) {
                        Text(CartoucheText.storageReadOnlyGames)
                            .font(.footnote)
                            .foregroundStyle(Color.orange)
                    }
                    Button(CartoucheText.storageReadAgain, systemImage: "arrow.clockwise") { stored.refresh(evenIfOffline: true) }
                        .disabled(stored.isScanning)
                } else if offline {
                    // As the games folder's lines: what waits, and a way to
                    // try the server again.
                    Label(CartoucheStorageOffline(server).localizedDescription, systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                    if !backups.waiting.isEmpty {
                        Text(CartoucheText.savesWaiting(backups.waiting.count))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    CartoucheTryAgainButton(isTrying: reach.trying.contains(server.id)) {
                        Task { await reach.tryAgain(server) }
                    }
                } else if settings.isReadOnly(.saves) {
                    Text(CartoucheText.storageReadOnlySaves)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                } else if let problem = backups.problemReport {
                    Text(problem.message)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                    CartoucheReportButton(report: problem)
                }
                Menu {
                    serverChoices(role)
                } label: {
                    Label(CartoucheText.storageChangeFolder, systemImage: "folder")
                }
                Button(role: .destructive) {
                    settings.setPlace(nil, for: role)
                    if role == .games { stored.refresh() }
                } label: {
                    Label(CartoucheText.storageStopUsing, systemImage: "xmark.circle")
                }
            } else if settings.servers.isEmpty {
                Text(CartoucheText.storageAddFirst)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    serverChoices(role)
                } label: {
                    Label(CartoucheText.storageChooseFolder, systemImage: "folder.badge.plus")
                }
            }
        } header: {
            Text(Self.title(role))
        } footer: {
            Text(role == .games ? CartoucheText.storageGamesFooter : CartoucheText.storageSavesFooter(CartoucheSaveBackups.kept))
        }
    }

    /// The servers to look for ROLE's folder on. A shared folder that lets
    /// the account read only shows, but cannot hold the saves.
    @ViewBuilder
    private func serverChoices(_ role: CartoucheStorageRole) -> some View {
        ForEach(settings.servers) { server in
            let readOnly = settings.readOnlyServers.contains(server.id)
            Button {
                browsing = Browsing(server: server, role: role)
            } label: {
                Label(readOnly ? CartoucheText.storageReadOnlyServer(server.name) : server.name,
                      systemImage: Self.symbol(server))
            }
            .disabled(readOnly && role == .saves)
        }
    }

    // MARK: Servers and folders

    private var serversSection: some View {
        Section {
            ForEach(settings.servers) { server in
                Button {
                    if server.kind != .folder { editing = server }
                } label: {
                    LabeledContent {
                        Text(Self.detail(server))
                            .lineLimit(1)
                    } label: {
                        Label(server.name, systemImage: Self.symbol(server))
                    }
                }
                .tint(.primary)
                .swipeActions {
                    Button(role: .destructive) {
                        remove(server)
                    } label: {
                        Label(CartoucheText.storageRemove, systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        remove(server)
                    } label: {
                        Label(CartoucheText.storageRemove, systemImage: "trash")
                    }
                }
            }
            Button {
                editing = CartoucheStorageServer(kind: .mac, name: "")
            } label: {
                Label(CartoucheText.storageAddMac, systemImage: "laptopcomputer")
            }
            if CartoucheStorage.hasSMB {
                Button {
                    editing = CartoucheStorageServer(kind: .smb, name: "")
                } label: {
                    Label(CartoucheText.storageAddSMB, systemImage: "server.rack")
                }
            }
            Button {
                editing = CartoucheStorageServer(kind: .s3, name: "")
            } label: {
                Label(CartoucheText.storageAddS3, systemImage: "cloud")
            }
            Button {
                editing = CartoucheStorageServer(kind: .ftp, name: "")
            } label: {
                Label(CartoucheText.storageAddFTP, systemImage: "externaldrive.connected.to.line.below")
            }
            if CartoucheStorage.hasSFTP {
                Button {
                    editing = CartoucheStorageServer(kind: .sftp, name: "")
                } label: {
                    Label(CartoucheText.storageAddSFTP, systemImage: "lock.shield")
                }
            }
            Button {
                choosingFolder = true
            } label: {
                Label(CartoucheText.storageAddFolder, systemImage: "folder.badge.plus")
            }
        } header: {
            Text(CartoucheText.storageServers)
        } footer: {
            Text(CartoucheText.storageServersFooter)
        }
    }

    private func remove(_ server: CartoucheStorageServer) {
        settings.remove(server)
        stored.refresh()
    }

    private func addFolder(_ url: URL) {
        do {
            let bookmark = try CartoucheFolder.bookmark(of: url)
            let name = FileManager.default.displayName(atPath: url.path)
            settings.save(CartoucheStorageServer(kind: .folder, name: name.isEmpty ? url.lastPathComponent : name,
                                                 bookmark: bookmark), secret: nil)
        } catch {
            NSLog("[Cartouche] cannot keep the folder %@: %@", url.path, error.localizedDescription)
        }
    }

    static func title(_ role: CartoucheStorageRole) -> String {
        role == .games ? CartoucheText.storageGamesFolder : CartoucheText.storageSavesFolder
    }

    static func symbol(_ role: CartoucheStorageRole) -> String {
        role == .games ? "square.stack.3d.up.fill" : "clock.arrow.circlepath"
    }

    static func symbol(_ server: CartoucheStorageServer) -> String {
        switch server.kind {
        case .smb: return "server.rack"
        case .folder: return "folder.fill"
        case .s3: return "cloud.fill"
        case .ftp: return "externaldrive.fill.badge.wifi"
        case .sftp: return "lock.shield.fill"
        case .mac: return "laptopcomputer"
        }
    }

    /// "NAS › Games › Switch", or the server's name alone for its root.
    static func placeName(server: CartoucheStorageServer, path: String) -> String {
        ([server.name] + path.split(separator: "/").map(String.init)).joined(separator: " › ")
    }

    static func detail(_ server: CartoucheStorageServer) -> String {
        switch server.kind {
        case .smb:
            let user = server.username.isEmpty ? CartoucheText.storageGuest : server.username
            return user + "@" + server.host + (server.share.isEmpty ? "" : "/" + server.share)
        case .folder:
            return CartoucheText.storageFilesFolder
        case .s3:
            let host = CartoucheS3Endpoint.parse(server.host)?.host ?? server.host
            return server.share + " · " + host
        case .ftp, .sftp:
            let port = server.port.map { ":\($0)" } ?? ""
            return "\(server.username)@\(server.host)\(port)"
        case .mac:
            return server.host.isEmpty ? "Cartouche Builder" : "Cartouche Builder · " + server.host
        }
    }
}

// MARK: A shared folder of a Mac, a PC or a NAS

@available(iOS 17.0, *)
struct CartoucheStorageServerForm: View {
    @State private var server: CartoucheStorageServer
    @State private var password = ""
    @State private var shares: [String]?
    @State private var checking = false
    @State private var problem: CartoucheReport?
    @StateObject private var nearby = CartoucheSMBBrowser()
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool

    init(server: CartoucheStorageServer) {
        _server = State(initialValue: server)
        isNew = CartoucheStorageSettings.shared.server(server.id) == nil
    }

    private var canSave: Bool {
        !server.host.trimmingCharacters(in: .whitespaces).isEmpty && !server.share.isEmpty && !checking
    }

    var body: some View {
        Form {
            if !nearby.found.isEmpty {
                Section(CartoucheText.storageNearby) {
                    ForEach(nearby.found) { found in
                        Button {
                            choose(found)
                        } label: {
                            Label(found.name, systemImage: server.host == found.host ? "checkmark.circle.fill" : "server.rack")
                        }
                        .disabled(found.host == nil)
                    }
                }
            }
            Section {
                TextField(CartoucheText.storageHost, text: $server.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(CartoucheText.storageUser, text: $server.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(isNew ? CartoucheText.storagePassword : CartoucheText.storagePasswordKept, text: $password)
                    .textContentType(.password)
            } header: {
                Text(CartoucheText.storageAccount)
            } footer: {
                Text(CartoucheText.storageAccountFooter)
            }
            Section {
                Button {
                    Task { await listShares() }
                } label: {
                    HStack {
                        Label(CartoucheText.storageConnect, systemImage: "network")
                        if checking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(server.host.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                if let shares {
                    if shares.isEmpty {
                        Text(CartoucheText.storageNoShares)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(CartoucheText.storageShare, selection: $server.share) {
                            ForEach(shares, id: \.self) { share in
                                Text(share).tag(share)
                            }
                        }
                    }
                } else if !server.share.isEmpty {
                    LabeledContent(CartoucheText.storageShare, value: server.share)
                }
                if let problem {
                    Text(problem.message)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                    CartoucheReportButton(report: problem)
                }
            } header: {
                Text(CartoucheText.storageShare)
            } footer: {
                Text(CartoucheText.storageShareFooter)
            }
            Section {
                TextField(CartoucheText.storageName, text: $server.name)
            } header: {
                Text(CartoucheText.storageNameTitle)
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(isNew ? CartoucheText.storageAddSMB : server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(CartoucheText.cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(CartoucheText.storageSave) { save() }
                    .disabled(!canSave)
            }
        }
        .onAppear { nearby.start() }
        .onDisappear { nearby.stop() }
    }

    private func choose(_ found: CartoucheSMBBrowser.Server) {
        guard let host = found.host else { return }
        server.host = host
        if server.name.isEmpty { server.name = found.name }
        shares = nil
        problem = nil
    }

    /// Signs in with what the form holds, and lists the shared folders.
    private func listShares() async {
        #if canImport(SMBClient)
        checking = true
        problem = nil
        server.host = server.host.trimmingCharacters(in: .whitespaces)
        let secret = password.isEmpty && !isNew ? (CartoucheStorageSettings.shared.secret(of: server) ?? "") : password
        do {
            let found = try await CartoucheSMB.shares(server, password: secret)
            shares = found
            if !found.contains(server.share) { server.share = found.first ?? "" }
        } catch {
            problem = CartoucheReports.connectionFailed(to: server, error: error)
        }
        checking = false
        #endif
    }

    private func save() {
        server.host = server.host.trimmingCharacters(in: .whitespaces)
        if server.name.trimmingCharacters(in: .whitespaces).isEmpty {
            server.name = server.host
        }
        // An empty password keeps the one saved, when there is one.
        CartoucheStorageSettings.shared.save(server, secret: password.isEmpty && !isNew ? nil : password)
        CartoucheStoredGames.shared.refresh()
        // Whether the shared folder lets this account write, for the choice
        // of the saves folder.
        let saved = server
        Task { await CartoucheStorageSettings.shared.checkAccess(of: saved) }
        dismiss()
    }
}

// MARK: An S3 bucket

@available(iOS 17.0, *)
struct CartoucheStorageS3Form: View {
    @State private var server: CartoucheStorageServer
    @State private var region: String
    @State private var secretKey = ""
    @State private var checking = false
    @State private var problem: CartoucheReport?
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool

    init(server: CartoucheStorageServer) {
        _server = State(initialValue: server)
        _region = State(initialValue: server.region ?? "")
        isNew = CartoucheStorageSettings.shared.server(server.id) == nil
    }

    private var canSave: Bool {
        let fields = [server.host, server.share, server.username]
        guard !fields.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        return (!secretKey.isEmpty || !isNew) && !checking
    }

    var body: some View {
        Form {
            Section {
                TextField(CartoucheText.storageS3Address, text: $server.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(CartoucheText.storageS3Bucket, text: $server.share)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(CartoucheText.storageS3Region, text: $region)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(CartoucheText.storageS3Server)
            } footer: {
                Text(CartoucheText.storageS3ServerFooter)
            }
            Section {
                TextField(CartoucheText.storageS3AccessKey, text: $server.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(isNew ? CartoucheText.storageS3SecretKey : CartoucheText.storageS3SecretKeyKept, text: $secretKey)
                if checking {
                    HStack {
                        Text(CartoucheText.storageS3Checking)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProgressView()
                    }
                }
                if let problem {
                    Text(problem.message)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                    CartoucheReportButton(report: problem)
                }
            } header: {
                Text(CartoucheText.storageS3Keys)
            } footer: {
                Text(CartoucheText.storageS3KeysFooter)
            }
            Section {
                TextField(CartoucheText.storageName, text: $server.name)
            } header: {
                Text(CartoucheText.storageNameTitle)
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(isNew ? CartoucheText.storageAddS3 : server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(CartoucheText.cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(CartoucheText.storageSave) { Task { await save() } }
                    .disabled(!canSave)
            }
        }
    }

    /// Signs in to the bucket with the keys the form holds, and keeps it
    /// only once the bucket lists for them.
    private func save() async {
        checking = true
        problem = nil
        server.host = CartoucheS3Endpoint.parse(server.host)?.text ?? server.host.trimmingCharacters(in: .whitespaces)
        server.share = server.share.trimmingCharacters(in: .whitespaces)
        server.username = server.username.trimmingCharacters(in: .whitespaces)
        let trimmedRegion = region.trimmingCharacters(in: .whitespaces)
        server.region = trimmedRegion.isEmpty ? nil : trimmedRegion
        if server.name.trimmingCharacters(in: .whitespaces).isEmpty {
            server.name = server.share
        }
        // An empty secret key keeps the one saved.
        let secret = secretKey.isEmpty && !isNew ? (CartoucheStorageSettings.shared.secret(of: server) ?? "") : secretKey
        let remote: CartoucheS3
        do {
            remote = try await CartoucheS3.connect(server, secretKey: secret)
        } catch {
            problem = CartoucheReports.connectionFailed(to: server, error: error)
            checking = false
            return
        }
        CartoucheStorageSettings.shared.save(server, secret: secretKey.isEmpty && !isNew ? nil : secretKey)
        // Whether the keys may write in the bucket, for the choice of the
        // saves folder.
        await CartoucheStorageSettings.shared.checkAccess(remote, server: server.id, path: "")
        await remote.disconnect()
        CartoucheStoredGames.shared.refresh()
        checking = false
        dismiss()
    }
}

// MARK: An FTP or SFTP server

@available(iOS 17.0, *)
struct CartoucheStorageFTPForm: View {
    @State private var server: CartoucheStorageServer
    @State private var port: String
    /// The server as it was saved, if it was.
    private let saved: CartoucheStorageServer?
    @State private var password = ""
    @State private var checking = false
    @State private var problem: CartoucheReport?
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool

    init(server: CartoucheStorageServer) {
        _server = State(initialValue: server)
        _port = State(initialValue: server.port.map(String.init) ?? "")
        saved = CartoucheStorageSettings.shared.server(server.id)
        isNew = saved == nil
    }

    private var isSFTP: Bool { server.kind == .sftp }
    private var defaultPort: Int { isSFTP ? 22 : 21 }

    private var canSave: Bool {
        let fields = [server.host, server.username]
        guard !fields.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        return portNumber != nil && !checking
    }

    /// The port typed, the protocol's when none; nil for what is not a
    /// port.
    private var portNumber: Int? {
        let typed = port.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return defaultPort }
        guard let number = Int(typed), (1 ... 65535).contains(number) else { return nil }
        return number
    }

    var body: some View {
        Form {
            Section {
                TextField(CartoucheText.storageHost, text: $server.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(CartoucheText.storagePort(defaultPort), text: $port)
                    .keyboardType(.numberPad)
                TextField(CartoucheText.storageUser, text: $server.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(isNew ? CartoucheText.storagePassword : CartoucheText.storagePasswordKept, text: $password)
                    .textContentType(.password)
                if isSFTP, let key = server.hostKey, let fingerprint = CartoucheSFTP.fingerprint(key) {
                    LabeledContent(CartoucheText.storageSFTPKey) {
                        Text(fingerprint)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if checking {
                    HStack {
                        Text(CartoucheText.storageFTPChecking)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProgressView()
                    }
                }
                if let problem {
                    Text(problem.message)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                    CartoucheReportButton(report: problem)
                }
            } header: {
                Text(CartoucheText.storageAccount)
            } footer: {
                Text(isSFTP ? CartoucheText.storageSFTPFooter : CartoucheText.storageFTPFooter)
            }
            Section {
                TextField(CartoucheText.storageName, text: $server.name)
            } header: {
                Text(CartoucheText.storageNameTitle)
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(isNew ? (isSFTP ? CartoucheText.storageAddSFTP : CartoucheText.storageAddFTP) : server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(CartoucheText.cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(CartoucheText.storageSave) { Task { await save() } }
                    .disabled(!canSave)
            }
        }
    }

    /// Signs in with what the form holds, and keeps the server only once
    /// the account got in.
    private func save() async {
        checking = true
        problem = nil
        server.host = server.host.trimmingCharacters(in: .whitespaces)
        server.username = server.username.trimmingCharacters(in: .whitespaces)
        server.port = portNumber == defaultPort ? nil : portNumber
        // Another server: its key is not the one kept.
        if saved?.host != server.host || saved?.port != server.port {
            server.hostKey = nil
        }
        if server.name.trimmingCharacters(in: .whitespaces).isEmpty {
            server.name = server.host
        }
        // An empty password keeps the one saved.
        let secret = password.isEmpty && !isNew ? (CartoucheStorageSettings.shared.secret(of: server) ?? "") : password
        let remote: CartoucheRemote
        do {
            let checked = try await CartoucheStorage.check(server, password: secret)
            remote = checked.remote
            server.hostKey = checked.hostKey
        } catch {
            problem = CartoucheReports.connectionFailed(to: server, error: error)
            checking = false
            return
        }
        CartoucheStorageSettings.shared.save(server, secret: password.isEmpty && !isNew ? nil : password)
        // Whether the account may write at the server's root, for the
        // choice of the saves folder.
        await CartoucheStorageSettings.shared.checkAccess(remote, server: server.id, path: "")
        await remote.disconnect()
        CartoucheStoredGames.shared.refresh()
        checking = false
        dismiss()
    }
}

/// The Macs, PCs and NASes that share folders on this network, as Bonjour
/// lists them (_smb._tcp), each with an address to sign in to.
final class CartoucheSMBBrowser: ObservableObject {
    struct Server: Identifiable, Hashable {
        let name: String
        /// Its address, once found.
        var host: String?
        var id: String { name }
    }

    @Published private(set) var found: [Server] = []
    private var browser: NWBrowser?
    private var lookups: [String: NWConnection] = [:]
    private let queue = DispatchQueue(label: "Cartouche SMB browser")

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> (String, NWEndpoint)? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return (name, result.endpoint)
            }
            DispatchQueue.main.async { self?.update(names) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for lookup in lookups.values { lookup.cancel() }
        lookups = [:]
    }

    private func update(_ services: [(String, NWEndpoint)]) {
        let names = Set(services.map(\.0))
        found = services.map { name, _ in
            found.first { $0.name == name } ?? Server(name: name, host: nil)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for (name, lookup) in lookups where !names.contains(name) {
            lookup.cancel()
            lookups[name] = nil
        }
        for (name, endpoint) in services where lookups[name] == nil && found.first(where: { $0.name == name })?.host == nil {
            resolve(name, endpoint)
        }
    }

    /// The service's IPv4 address, from a connection to it.
    private func resolve(_ name: String, _ endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let connection else { return }
            var address: String?
            if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                switch host {
                case let .ipv4(ipv4): address = "\(ipv4)"
                case let .name(text, _): address = text
                default: address = nil
                }
            }
            connection.cancel()
            // Without the interface an address may end with (%en0).
            guard let resolved = address?.split(separator: "%").first.map(String.init) else { return }
            DispatchQueue.main.async {
                guard let self, let index = self.found.firstIndex(where: { $0.name == name }) else { return }
                self.found[index].host = resolved
            }
        }
        lookups[name] = connection
        connection.start(queue: queue)
    }
}

// MARK: Choosing a folder

@available(iOS 17.0, *)
struct CartoucheStorageFolderBrowser: View {
    let server: CartoucheStorageServer
    let path: String
    let role: CartoucheStorageRole
    let onChoose: (String) -> Void
    @State private var folders: [String]?
    @State private var problem: CartoucheReport?
    /// Why the server did not answer, when it is offline from here.
    @State private var offline: String?
    /// Whether the account can add a file here: nil until the server
    /// answers, and when it did not.
    @State private var writable: Bool?
    @State private var checked = false
    @State private var naming = false
    @State private var newName = ""

    init(server: CartoucheStorageServer, path: String, role: CartoucheStorageRole, onChoose: @escaping (String) -> Void) {
        self.server = server
        self.path = path
        self.role = role
        self.onChoose = onChoose
    }

    var body: some View {
        List {
            Section {
                Button {
                    onChoose(path)
                } label: {
                    Label(CartoucheText.storageUseThisFolder, systemImage: "checkmark.circle.fill")
                        .font(.headline)
                }
                // The saves need a folder Cartouche can write to.
                .disabled(role == .saves && (!checked || writable == false))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(CartoucheStorageView.placeName(server: server, path: path))
                    if writable == false {
                        Text(role == .games ? CartoucheText.storageReadOnlyGames : CartoucheText.storageReadOnlySaves)
                            .foregroundStyle(Color.orange)
                    }
                }
            }
            Section {
                if let folders {
                    ForEach(folders, id: \.self) { name in
                        NavigationLink {
                            CartoucheStorageFolderBrowser(server: server, path: CartoucheStoragePath.join(path, name),
                                                          role: role, onChoose: onChoose)
                        } label: {
                            Label(name, systemImage: "folder.fill")
                        }
                    }
                    if folders.isEmpty {
                        Text(CartoucheText.storageNoFolders)
                            .foregroundStyle(.secondary)
                    }
                } else if let offline {
                    CartoucheOfflineRows(message: offline) {
                        self.offline = nil
                        Task { await load() }
                    }
                } else if let problem {
                    Text(problem.message)
                        .foregroundStyle(Color.orange)
                    CartoucheReportButton(report: problem)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(path.isEmpty ? server.name : CartoucheStoragePath.name(path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(CartoucheText.storageNewFolder, systemImage: "folder.badge.plus") {
                    newName = role == .games ? CartoucheText.gamesTab : CartoucheText.savesTitle
                    naming = true
                }
                .disabled(folders == nil || writable == false)
            }
        }
        .alert(CartoucheText.storageNewFolder, isPresented: $naming) {
            TextField(CartoucheText.storageName, text: $newName)
            Button(CartoucheText.storageCreate) { Task { await makeFolder() } }
            Button(CartoucheText.cancel, role: .cancel) {}
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let remote = try await CartoucheStorage.connect(server)
            let items: [CartoucheRemoteItem]
            do {
                items = try await remote.list(path)
            } catch {
                await remote.disconnect()
                throw error
            }
            writable = await CartoucheStorageSettings.shared.checkAccess(remote, server: server.id, path: path)
            checked = true
            await remote.disconnect()
            folders = items.filter(\.isFolder).map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            problem = nil
        } catch let away as CartoucheStorageOffline {
            // No problem to report: the player is away from the server.
            offline = away.localizedDescription
        } catch {
            problem = CartoucheReports.make(.storage, CartoucheText.storageBrowseFailed, message: error.localizedDescription,
                                            error: error, step: "Listing a folder on " + CartoucheReports.kindName(server.kind),
                                            facts: [.init("Depth", String(path.split(separator: "/").count))])
        }
    }

    private func makeFolder() async {
        let name = CartoucheStoragePath.fileName(newName)
        do {
            let remote = try await CartoucheStorage.connect(server)
            do {
                try await remote.makeFolder(CartoucheStoragePath.join(path, name))
            } catch {
                await remote.disconnect()
                throw error
            }
            await remote.disconnect()
            folders = ((folders ?? []) + [name]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch let away as CartoucheStorageOffline {
            folders = nil
            offline = away.localizedDescription
        } catch {
            // The name the player just typed is theirs too.
            CartoucheReports.redactTyped(names: [name])
            problem = CartoucheReports.make(.storage, CartoucheText.storageNewFolderFailed, message: error.localizedDescription,
                                            error: error, step: "Creating a folder on " + CartoucheReports.kindName(server.kind))
        }
    }
}

// MARK: A game's saves, on its sheet

@available(iOS 17.0, *)
struct CartoucheSavesSection: View {
    let target: CartoucheSaveTarget
    @ObservedObject var backups = CartoucheSaveBackups.shared
    @ObservedObject private var settings = CartoucheStorageSettings.shared
    @ObservedObject private var reach = CartoucheStorageReach.shared
    @State private var copying = false

    init(target: CartoucheSaveTarget) {
        self.target = target
    }

    var body: some View {
        Section {
            if let location = settings.location(.saves) {
                LabeledContent(CartoucheText.savesLastCopy) {
                    if let date = backups.lastCopy[target.key] {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text(CartoucheText.savesNoCopy)
                    }
                }
                if settings.isReadOnly(.saves) {
                    Text(CartoucheText.savesReadOnly)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                } else {
                    Button {
                        copying = true
                        Task {
                            _ = await backups.copyNow(target)
                            copying = false
                        }
                    } label: {
                        HStack {
                            Label(CartoucheText.savesCopyNow(location.server.name), systemImage: "arrow.up.doc.fill")
                            if copying || backups.isCopying {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(copying || backups.isCopying)
                }
                NavigationLink {
                    CartoucheSaveCopiesView(target: target)
                } label: {
                    Label(CartoucheText.savesPutBack, systemImage: "clock.arrow.circlepath")
                }
                if reach.isOffline(location.server.id) {
                    Label(CartoucheStorageOffline(location.server).localizedDescription, systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                    if backups.waiting.contains(target.key) {
                        Text(CartoucheText.savesWaitingHere)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let problem = backups.problemReport {
                    Text(problem.message)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                    CartoucheReportButton(report: problem)
                }
            } else {
                Text(CartoucheText.savesNoFolder)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(CartoucheText.savesTitle)
        } footer: {
            Text(CartoucheText.savesFooter(CartoucheSaveBackups.kept))
        }
    }
}

/// A game's copies of saves, the newest first: one is put back after a
/// question.
@available(iOS 17.0, *)
struct CartoucheSaveCopiesView: View {
    let target: CartoucheSaveTarget
    @State private var copies: [CartoucheSaveBackup]?
    @State private var problem: CartoucheReport?
    @State private var asking: CartoucheSaveBackup?
    @State private var restoring = false
    @State private var restored: Date?
    /// Why the last copy was not put back, and the report on it.
    @State private var failure: CartoucheReport?
    /// Why the server did not answer, when it is offline from here: for
    /// the list, and for the last copy put back.
    @State private var offline: String?
    @State private var restoreOffline: String?

    init(target: CartoucheSaveTarget) {
        self.target = target
    }

    var body: some View {
        List {
            if let restored {
                Section {
                    Label(CartoucheText.savesPutBackDone(restored.formatted(date: .abbreviated, time: .shortened)),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                }
            }
            if let failure {
                Section {
                    Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    CartoucheReportButton(report: failure)
                }
            } else if let restoreOffline {
                Section {
                    Label(restoreOffline, systemImage: "wifi.slash")
                        .foregroundStyle(Color.orange)
                }
            }
            Section {
                if let copies {
                    ForEach(copies) { copy in
                        Button {
                            asking = copy
                        } label: {
                            LabeledContent {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: copy.size), countStyle: .file))
                            } label: {
                                Label(copy.date.formatted(date: .abbreviated, time: .shortened), systemImage: "doc.zipper")
                            }
                        }
                        .tint(.primary)
                        .disabled(restoring)
                    }
                    if copies.isEmpty {
                        Text(CartoucheText.savesNoCopy)
                            .foregroundStyle(.secondary)
                    }
                } else if let offline {
                    CartoucheOfflineRows(message: offline) {
                        self.offline = nil
                        Task { await load() }
                    }
                } else if let problem {
                    Text(problem.message)
                        .foregroundStyle(Color.orange)
                    CartoucheReportButton(report: problem)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } footer: {
                Text(CartoucheText.savesPutBackFooter)
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(CartoucheText.savesPutBack)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if restoring {
                ProgressView()
                    .controlSize(.large)
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .confirmationDialog(CartoucheText.savesPutBackQuestion, isPresented: askingShown, titleVisibility: .visible,
                            presenting: asking) { copy in
            Button(CartoucheText.savesPutBackAction(copy.date.formatted(date: .abbreviated, time: .shortened)),
                   role: .destructive) {
                Task { await restore(copy) }
            }
            Button(CartoucheText.cancel, role: .cancel) {}
        } message: { _ in
            Text(CartoucheText.savesPutBackMessage)
        }
        .task { await load() }
        // The server answers again: the list it could not give comes.
        .onReceive(CartoucheStorageReach.shared.cameBack) { _ in
            guard offline != nil else { return }
            offline = nil
            Task { await load() }
        }
    }

    private var askingShown: Binding<Bool> {
        Binding(get: { asking != nil }, set: { shown in if !shown { asking = nil } })
    }

    private func load() async {
        do {
            copies = try await CartoucheSaveBackups.shared.copies(of: target)
            problem = nil
            offline = nil
        } catch let away as CartoucheStorageOffline {
            // No problem to report: the player is away from the server.
            copies = nil
            offline = away.localizedDescription
        } catch {
            problem = CartoucheReports.make(.saves, CartoucheText.savesListFailed, message: error.localizedDescription,
                                            error: error, step: "Listing the copies of " + target.name + "'s saves, in "
                                                + CartoucheReports.place(.saves))
        }
    }

    private func restore(_ copy: CartoucheSaveBackup) async {
        restoring = true
        restored = nil
        failure = nil
        restoreOffline = nil
        do {
            try await CartoucheSaveBackups.shared.restore(copy, of: target)
            restored = copy.date
            CartoucheReports.note("Saves of " + target.name + " put back from " + CartoucheReport.timestamp(copy.date))
        } catch let away as CartoucheStorageOffline {
            restoreOffline = away.localizedDescription
        } catch {
            failure = CartoucheReports.make(.saves, CartoucheText.savesPutBackFailed, message: error.localizedDescription,
                                            error: error, step: "Putting back a copy of " + target.name + "'s saves",
                                            facts: [.init("Copy", CartoucheReport.timestamp(copy.date) + ", "
                                                + CartoucheReport.bytes(Int64(clamping: copy.size)))])
        }
        restoring = false
        // Putting a copy back first copies the saves it replaces.
        await load()
    }
}

/// A server that does not answer from here, where what it holds would
/// show, with a button that tries it again.
@available(iOS 17.0, *)
struct CartoucheOfflineRows: View {
    let message: String
    var isTrying = false
    let tryAgain: () -> Void

    var body: some View {
        Label(message, systemImage: "wifi.slash")
            .foregroundStyle(Color.orange)
        CartoucheTryAgainButton(isTrying: isTrying, action: tryAgain)
    }
}

/// Try again, for a server that does not answer from here: busy while it
/// is being tried.
@available(iOS 17.0, *)
struct CartoucheTryAgainButton: View {
    var isTrying = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(CartoucheText.storageTryAgain, systemImage: "arrow.clockwise")
                if isTrying {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isTrying)
    }
}
