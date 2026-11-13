//
//  CartoucheGameLogView.swift
//  Cartouche
//
//  A game's log, from its sheet (Share the log): what the game wrote of its
//  last two sessions, and the two ways to pass it on. Send the log… shares
//  the logs as the game wrote them, in a zip with a summary, by Messages,
//  Mail, AirDrop or any app of the share sheet, to whoever the player
//  picks. Send to Cartouche sends Cartouche's server the summary and the
//  start and the end of each log, cleaned, which the player can see first
//  (CartoucheGameLogSentView); the server files them in the project's
//  private repository, as a problem report. Nothing leaves until the
//  player taps one or the other (CartoucheGameLogShare.swift).
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheGameLogView: View {
    let folder: CartoucheGameLogFolder
    /// The game's colours, as its sheet has them.
    let tileKey: String
    @State private var loaded: Loaded?
    @State private var what = ""
    @State private var sending = CartoucheReportView.Sending.ready
    /// The number of what Send to Cartouche sends: the same when it tries
    /// again, a new one once it is sent.
    @State private var submissionID = CartoucheProblemSubmission.newID()

    // Written out: the private state above would make the synthesized
    // initializer private.
    init(folder: CartoucheGameLogFolder, tileKey: String) {
        self.folder = folder
        self.tileKey = tileKey
    }

    /// What the page reads when it opens.
    private struct Loaded {
        /// The logs as the game wrote them.
        var share: CartoucheGameLogShare
        /// The zip Send the log… shares, once made.
        var zip: URL?
        var zipFailure: String?
    }

    /// Where the zip waits for the share sheet, in Cartouche's own
    /// temporary folder: emptied as a log's page opens, and by iOS.
    private static var zipFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Game logs", isDirectory: true)
    }

    var body: some View {
        List {
            Section {
                if let loaded {
                    if loaded.share.logs.isEmpty {
                        Text(CartoucheText.gameLogNone)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(loaded.share.logs, id: \.name) { log in
                        session(log)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } footer: {
                Text(CartoucheText.gameLogFooter)
            }

            Section {
                if let zip = loaded?.zip {
                    ShareLink(item: zip, subject: Text(verbatim: zip.deletingPathExtension().lastPathComponent)) {
                        Label(CartoucheText.gameLogShare, systemImage: "square.and.arrow.up")
                    }
                } else if let failure = loaded?.zipFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else if loaded?.share.logs.isEmpty != true {
                    Label {
                        Text(CartoucheText.gameLogPreparing)
                    } icon: {
                        ProgressView()
                    }
                    .foregroundStyle(.secondary)
                }
            } footer: {
                Text(CartoucheText.gameLogShareFooter)
            }

            if let endpoint = CartoucheTelemetry.endpoint {
                Section {
                    TextField(CartoucheText.gameLogWhatPrompt, text: $what, axis: .vertical)
                        .lineLimit(2...8)
                    Button {
                        send(to: endpoint)
                    } label: {
                        sendLabel
                    }
                    .disabled(loaded == nil || sending == .sending || sending == .sent)
                    if case .failed(let reason) = sending {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    NavigationLink {
                        if let share = toSend {
                            CartoucheGameLogSentView(share: share, tileKey: tileKey)
                        }
                    } label: {
                        Label(CartoucheText.gameLogWhatIsSent, systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(loaded == nil)
                } footer: {
                    Text(CartoucheText.gameLogSendFooter)
                }
            }
        }
        .cartoucheStageBackground(key: tileKey)
        .navigationTitle(CartoucheText.gameLogTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: what) {
            if sending != .sending {
                sending = .ready
            }
        }
    }

    /// A session: which one, when and how long its log is, and whether the
    /// game crashed.
    private func session(_ log: CartoucheGameLogDigest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(log.name == CartoucheGameLogShare.names[0] ? CartoucheText.gameLogLast : CartoucheText.gameLogBefore)
                .font(.headline)
            Text(verbatim: Self.details(of: log))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if log.crash != nil {
                Label(CartoucheText.gameLogCrashed, systemImage: "exclamationmark.octagon")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "13 Nov 2026, 20:41 – 21:02 · 245 KB", in the reader's language.
    static func details(of log: CartoucheGameLogDigest) -> String {
        var parts: [String] = []
        if let start = log.created ?? log.modified {
            var when = start.formatted(date: .abbreviated, time: .shortened)
            if let end = log.modified, log.created != nil, end > start {
                when += " – " + end.formatted(date: Calendar.current.isDate(start, inSameDayAs: end) ? .omitted : .abbreviated,
                                              time: .shortened)
            }
            parts.append(when)
        }
        parts.append(CartoucheText.size(bytes: UInt64(max(log.bytes, 0))))
        return parts.joined(separator: " · ")
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

    /// What Send to Cartouche sends: the logs, with what the player wrote.
    private var toSend: CartoucheGameLogShare? {
        guard var share = loaded?.share else { return nil }
        share.what = what
        return share
    }

    // MARK: Reading

    /// The logs of FOLDER as a report has them, with Cartouche and the
    /// device, cleaned with the names the player's settings hold when they
    /// go to Cartouche.
    @MainActor
    static func share(of folder: CartoucheGameLogFolder, logs: [CartoucheGameLogDigest],
                      date: Date = Date()) -> CartoucheGameLogShare {
        CartoucheGameLogShare(game: folder.game, titleId: folder.titleId, build: folder.build,
                              environment: CartoucheReports.environment(), logs: logs, date: date,
                              cleaning: CartoucheLogCleaning(redaction: CartoucheReports.redaction()))
    }

    /// Reads the logs, away from the main thread, then makes the zip.
    @MainActor
    private func load() async {
        guard loaded == nil else { return }
        let files = folder.files
        let logs = await Task.detached(priority: .userInitiated) {
            files.compactMap { CartoucheGameLogDigest.read($0, name: $0.lastPathComponent) }
        }.value
        let share = Self.share(of: folder, logs: logs)
        loaded = Loaded(share: share)
        guard !logs.isEmpty else { return }
        let name = CartoucheGameLogShare.fileName(game: folder.game, date: share.date, word: CartoucheText.gameLogFileWord)
        let summary = share.summary
        let zips = Self.zipFolder
        do {
            let zip = try await Task.detached(priority: .userInitiated) {
                try? FileManager.default.removeItem(at: zips)
                return try await CartoucheGameLogShare.writeZip(named: name, summary: summary, logs: files, in: zips)
            }.value
            loaded?.zip = zip
        } catch {
            CartoucheReports.note("Game log not zipped: \(error.localizedDescription)")
            loaded?.zipFailure = CartoucheText.gameLogZipFailed(error.localizedDescription)
        }
    }

    // MARK: Send to Cartouche

    @MainActor
    private func send(to endpoint: URL) {
        guard let share = toSend else { return }
        let id = submissionID
        sending = .sending
        Task {
            // Cleaned away from the main thread: a few thousand lines.
            let body = await Task.detached(priority: .userInitiated) {
                try? share.submission(id: id)?.json()
            }.value
            guard let body else {
                sending = .failed(CartoucheText.reportSendRefused)
                return
            }
            let sent = await CartoucheReportView.post(body, to: endpoint)
            sending = sent
            if sent == .sent {
                CartoucheReports.note("Game log sent to Cartouche")
                submissionID = CartoucheProblemSubmission.newID()
            }
        }
    }
}

/// What Send to Cartouche sends of a game's log, as the server files it:
/// its title, then the summary and the start and the end of each log,
/// cleaned.
@available(iOS 17.0, *)
struct CartoucheGameLogSentView: View {
    let share: CartoucheGameLogShare
    let tileKey: String
    @State private var submission: CartoucheProblemSubmission?

    init(share: CartoucheGameLogShare, tileKey: String) {
        self.share = share
        self.tileKey = tileKey
    }

    /// Lines shown together: one Text each, so that the page lays out
    /// only what it shows.
    private static let linesPerPart = 40

    var body: some View {
        List {
            if let submission {
                Section {
                    Text(verbatim: submission.title)
                        .font(.headline)
                        .textSelection(.enabled)
                    let parts = Self.parts(of: submission.logs)
                    ForEach(parts.indices, id: \.self) { index in
                        Text(verbatim: parts[index])
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } footer: {
                    Text(CartoucheText.gameLogSentFooter)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .cartoucheStageBackground(key: tileKey)
        .navigationTitle(CartoucheText.gameLogWhatIsSent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let share = self.share
            submission = await Task.detached(priority: .userInitiated) {
                share.submission(id: CartoucheProblemSubmission.newID())
            }.value
        }
    }

    static func parts(of text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return stride(from: 0, to: lines.count, by: linesPerPart).map { start in
            lines[start..<min(start + linesPerPart, lines.count)].joined(separator: "\n")
        }
    }
}
