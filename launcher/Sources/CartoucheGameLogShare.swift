//
//  CartoucheGameLogShare.swift
//  Cartouche
//
//  A game's log, as the player shares it from the game's sheet: the log
//  nxnative wrote of the game's last session, Documents/log.txt of its data
//  folder, and of the session before, log.prev.txt, which nxnative renames
//  it to at the game's next start (dm/ios/Sources/main.m). Two ways, and
//  nothing leaves until the player takes one. The share sheet shares both
//  logs as the game wrote them, in a zip with a summary, to whoever the
//  player picks (CartoucheGameLogZip.swift). Send to Cartouche sends
//  Cartouche's server the summary and the start and the end of each log,
//  cleaned first (CartoucheLogCleaning), which it files as an issue of the
//  project's private repository (telemetry/worker.js, POST /v1/problems).
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

// MARK: What a log must not take to Cartouche

/// Takes out of a game's log, line by line, what Send to Cartouche must not
/// send: what a report never holds (CartoucheRedaction: the names the
/// player's settings hold, any address, the folders iOS gives the device's
/// apps), and what a log adds to it: any other path of the device's, such
/// as the folder in Files a game keeps its cloud saves in; the numbers that
/// name the device's folders and installs, UUIDs; anything shaped like a
/// key; the nickname a player may give the game (DM_NICK); and the memory
/// a crash, or a thread's state, writes out word by word (nxnative's
/// crash.c and hle_thread.c), which may hold whatever the game had in
/// memory. What tells where a game crashed stays: the crash line, the
/// registers, the backtraces and the module offsets.
struct CartoucheLogCleaning: Sendable {
    /// The player's own names and the shapes of a report.
    var redaction: CartoucheRedaction

    init(redaction: CartoucheRedaction = .shapes) {
        self.redaction = redaction
    }

    /// What stands in for what is taken out, beside CartoucheRedaction's.
    static let path = CartoucheRedaction.path
    static let id = "<id>"
    static let key = "<key>"
    static let memory = "<memory>"

    /// The longest line kept, in UTF-8 bytes: past it, a line loses its
    /// end, so that no line takes the expressions long.
    static let longestLine = 16_384

    func clean(_ line: String) -> String {
        cleaner()(line)
    }

    /// clean(_:) for many lines, the player's names made into expressions
    /// once.
    func cleaner() -> (String) -> String {
        let redact = redaction.redactor()
        return { line in
            guard !line.isEmpty else { return line }
            var line = Self.shortened(line)
            // Word by word first, before anything else changes the words.
            line = Self.withoutMemory(line)
            // The folders of apps, then any other path whole, before what
            // is in it, such as an e-mail address, goes and splits it.
            line = Self.replace(CartoucheRedaction.appContainer, in: line, with: CartoucheRedaction.container)
            line = Self.replace(Self.otherPath, in: line, with: Self.path)
            line = redact(line)
            line = Self.replace(Self.uuid, in: line, with: Self.id)
            line = Self.replace(Self.hexKey, in: line, with: Self.key)
            line = Self.withoutEncodedKeys(line)
            line = Self.replace(Self.nickname, in: line, with: CartoucheRedaction.name)
            return line
        }
    }

    // MARK: The rules

    /// A path of the device's, or of a Mac's, outside the folders iOS gives
    /// apps, which go first: what the player named their folders is in it,
    /// and Google Drive's folder in Files has the player's e-mail address in
    /// its name. It goes up to what ends a path in nxnative's lines: ": ",
    /// " (", a bracket, a quote, a quote's end, or the end of the line, an
    /// apostrophe inside a name staying in it ("Saves d'Élodie"); the system's
    /// own folders stay, and so do the folders inside an app's,
    /// "<container>/tmp".
    private static let otherPath = regex(
        #"(?<![A-Za-z0-9_.~/>\-])/(?:private|var|Users|Volumes|home|mnt|tmp)(?:/[^\n"“”«»<>]*?)?"#
            + #"(?=: |, |; | \(|\)|\]|["“”«»<>]|['’](?=[\s:,;.)\]]|\z)|\s*\z)"#)
    /// What names the device's folders and installs, such as a game's data
    /// folder in LiveContainer: "5A3C1B2D-…".
    private static let uuid = regex(
        #"(?<![0-9A-Fa-f])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?![0-9A-Fa-f])"#)
    /// 128 bits or more in hexadecimal: a key's length. nxnative's commits,
    /// shader chains and title IDs are shorter, and stay.
    private static let hexKey = regex(#"(?<![0-9A-Za-z])(?:0x)?[0-9A-Fa-f]{32,}(?![0-9A-Za-z])"#)
    /// A word of base64 long enough to be a key or a token.
    private static let encoded = regex(#"(?<![A-Za-z0-9+/=_\-])[A-Za-z0-9+/_\-]{40,}={0,2}(?![A-Za-z0-9+/=_\-])"#)
    /// The nickname nxnative gives the game's user, from its environment,
    /// up to the file that set it: "boot: env DM_NICK=Lou (env.txt)".
    private static let nickname = regex(#"(?<=DM_NICK=)[^\n]*?[^\s](?=\s\([^()\n]*\)\s*\z|\s*\z)"#)

    /// LINE, cut at longestLine, with what says how much went.
    private static func shortened(_ line: String) -> String {
        let bytes = line.utf8.count
        guard bytes > longestLine else { return line }
        var kept = line.utf8.prefix(longestLine)
        // Not in the middle of a character.
        while let last = kept.last, last & 0xC0 == 0x80 { kept = kept.dropLast() }
        if let last = kept.last, last >= 0xC0 { kept = kept.dropLast() }
        return (String(kept) ?? "") + " [\(bytes - kept.count) bytes cut]"
    }

    /// A word of base64, 40 characters or more, with digits, capitals and
    /// small letters, as a key or a token is: not a C++ or Swift symbol,
    /// which nxnative names functions by, nor a word of letters alone.
    private static func withoutEncodedKeys(_ line: String) -> String {
        guard line.utf8.count >= 40 else { return line }
        var line = line
        let range = NSRange(line.startIndex..., in: line)
        for match in encoded.matches(in: line, range: range).reversed() {
            guard let found = Range(match.range, in: line) else { continue }
            let word = line[found]
            guard !word.hasPrefix("_Z"), !word.hasPrefix("$s"), word.contains(where: \.isNumber),
                  word.contains(where: \.isUppercase), word.contains(where: \.isLowercase) else { continue }
            line.replaceSubrange(found, with: key)
        }
        return line
    }

    /// LINE without the words of memory it writes out: in a run of four
    /// numbers or more, as a crash writes what its registers point at, or
    /// a thread the top of its stack, at least one of eight hexadecimal
    /// digits or more, each number of five digits or more goes, the run's
    /// small numbers and module offsets ("main+0x1a2b") staying; numbers
    /// that went side by side go as one.
    static func withoutMemory(_ line: String) -> String {
        // A backtrace's addresses are where the code was, not what memory
        // held.
        guard line.utf8.count >= 30, !line.contains("bt:"), !line.contains("backtrace:"),
              !line.contains("stack scan") else { return line }
        var pieces = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var changed = false
        var index = 0
        while index < pieces.count {
            // A run: the pieces from INDEX that are numbers or offsets, the
            // empty ones of several spaces between them.
            var end = index
            var words = 0
            var long = false
            while end < pieces.count {
                let piece = pieces[end]
                if piece.isEmpty {
                    end += 1
                    continue
                }
                guard let digits = hexDigits(piece) else {
                    guard isOffset(piece) else { break }
                    words += 1
                    end += 1
                    continue
                }
                words += 1
                if digits >= 8 { long = true }
                end += 1
            }
            if words >= 4, long {
                var previousWasMemory = false
                for position in index..<end {
                    let piece = pieces[position]
                    if piece.isEmpty { continue }
                    if let digits = hexDigits(piece), digits >= 5 {
                        pieces[position] = previousWasMemory ? "" : memory
                        previousWasMemory = true
                        changed = true
                    } else {
                        previousWasMemory = false
                    }
                }
            }
            index = max(end, index + 1)
        }
        guard changed else { return line }
        // The spaces of the numbers that went with the one before them.
        var kept: [String] = []
        var skipping = false
        for piece in pieces {
            if piece == memory {
                skipping = true
                kept.append(piece)
            } else if skipping, piece.isEmpty {
                continue
            } else {
                skipping = false
                kept.append(piece)
            }
        }
        return kept.joined(separator: " ")
    }

    /// The hexadecimal digits of PIECE, if it is a number as nxnative writes
    /// a word of memory: "0x16fdff000", "1a2b3c4d", "0".
    private static func hexDigits(_ piece: String) -> Int? {
        var digits = Substring(piece)
        if digits.hasPrefix("0x") { digits = digits.dropFirst(2) }
        guard !digits.isEmpty, digits.utf8.allSatisfy(isHexDigit) else { return nil }
        return digits.utf8.count
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    /// Whether PIECE is a module offset, as nxnative names an address in a
    /// module: "main+0x1a2b3c".
    private static func isOffset(_ piece: String) -> Bool {
        piece.contains("+0x") && CartoucheGameLogReader.location(piece) != nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns above are fixed: one that does not compile is a bug
        // that the tests show.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func replace(_ expression: NSRegularExpression, in text: String, with mark: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range,
                                                   withTemplate: NSRegularExpression.escapedTemplate(for: mark))
    }
}

// MARK: Where a game's logs are

/// A game's logs where nxnative writes them, and what the summary says of
/// the game.
struct CartoucheGameLogFolder: Hashable {
    /// The game's name, as its sheet shows it.
    var game: String
    var titleId: String?
    /// The build installed.
    var build: CartoucheGameBuild?
    /// The game's Documents folder, in its data folder.
    var documents: URL

    /// The logs the game wrote, the last session's first.
    var files: [URL] {
        CartoucheGameLogShare.names.map { documents.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: One log

/// One of a game's logs, read: what the summary says of it, its first and
/// its last lines, and the lines that say what went wrong.
struct CartoucheGameLogDigest: Equatable, Sendable {
    /// The first lines kept, and the last: a session's start says how the
    /// game started, its end how it ended.
    static let headKept = 300
    static let tailKept = 600
    /// The lines nxnative marks as problems ([RED]) and the crash lines
    /// kept, the first ones.
    static let notableKept = 20
    /// A log is read up to this size: a long session writes a few
    /// megabytes.
    static let maximumBytes = 64 << 20

    /// "log.txt", or "log.prev.txt".
    var name: String
    /// When nxnative started it, and last wrote in it.
    var created: Date?
    var modified: Date?
    /// Its size as nxnative wrote it.
    var bytes = 0
    var lines = 0
    var head: [String] = []
    /// The last lines after the head, oldest first.
    var tail: [String] = []
    var notable: [String] = []
    /// The crash line, if the game crashed: "[dm] CRASH sig=11 …".
    var crash: String?
    /// Whether the log was longer than maximumBytes, and read up to it.
    var isCut = false

    init(name: String, created: Date? = nil, modified: Date? = nil) {
        self.name = name
        self.created = created
        self.modified = modified
    }

    /// The digest of TEXT, a whole log.
    static func of(text: String, name: String, created: Date? = nil, modified: Date? = nil) -> CartoucheGameLogDigest {
        var digest = CartoucheGameLogDigest(name: name, created: created, modified: modified)
        digest.read(Data(text.utf8))
        return digest
    }

    /// The digest of the log at URL; nil if it cannot be read.
    static func read(_ url: URL, name: String) -> CartoucheGameLogDigest? {
        // Mapped, not copied into Cartouche's memory: iOS counts only the
        // pages read, and gives them back.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        var digest = CartoucheGameLogDigest(name: name, created: attributes?[.creationDate] as? Date,
                                            modified: attributes?[.modificationDate] as? Date)
        digest.read(data)
        return digest
    }

    /// Takes the lines of DATA, up to maximumBytes.
    private mutating func read(_ data: Data) {
        bytes = data.count
        isCut = data.count > Self.maximumBytes
        let end = min(data.count, Self.maximumBytes)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var start = 0
            while start < end {
                var stop = start
                while stop < end, raw[stop] != 0x0A { stop += 1 }
                add(String(decoding: raw[start..<stop], as: UTF8.self))
                start = stop + 1
            }
        }
    }

    /// Takes LINE as the next line of the log.
    mutating func add(_ line: String) {
        lines += 1
        if head.count < Self.headKept {
            head.append(line)
        } else {
            tail.append(line)
            // Trimmed now and then rather than at each line.
            if tail.count >= 2 * Self.tailKept {
                tail.removeFirst(tail.count - Self.tailKept)
            }
        }
        let isCrash = line.contains("CRASH sig=")
        if isCrash, crash == nil { crash = line }
        if (isCrash || line.contains("[RED]")) && notable.count < Self.notableKept {
            notable.append(line)
        }
    }

    /// The last lines, at most tailKept.
    var lastLines: [String] { Array(tail.suffix(Self.tailKept)) }

    /// The number of the first of the last lines.
    var firstOfLast: Int { lines - lastLines.count + 1 }

    /// The same, each line kept cleaned by CLEAN.
    func cleaned(by clean: (String) -> String) -> CartoucheGameLogDigest {
        var cleaned = self
        cleaned.head = head.map(clean)
        cleaned.tail = lastLines.map(clean)
        cleaned.notable = notable.map(clean)
        cleaned.crash = crash.map(clean)
        return cleaned
    }
}

// MARK: What the player shares

/// A game's logs as the player shares them: the summary, which goes first
/// either way, and what Send to Cartouche sends, cleaned.
struct CartoucheGameLogShare {
    /// The game's name, as its sheet shows it.
    var game: String
    var titleId: String?
    /// The build installed.
    var build: CartoucheGameBuild?
    /// What the player wrote of what happened, as they wrote it.
    var what: String
    /// Cartouche and the device (CartoucheReports.environment()).
    var environment: CartoucheReport.Environment
    /// log.txt first, then log.prev.txt: those the game has.
    var logs: [CartoucheGameLogDigest]
    var date: Date
    /// What takes out of the logs, of what the player wrote and of the
    /// facts what Send to Cartouche must not send.
    var cleaning: CartoucheLogCleaning
    /// Whether they are cleaned already (cleaned()).
    private(set) var isCleaned = false

    init(game: String, titleId: String? = nil, build: CartoucheGameBuild? = nil, what: String = "",
         environment: CartoucheReport.Environment, logs: [CartoucheGameLogDigest], date: Date = Date(),
         cleaning: CartoucheLogCleaning = CartoucheLogCleaning()) {
        self.game = game
        self.titleId = titleId
        self.build = build
        self.what = what
        self.environment = environment
        self.logs = logs
        self.date = date
        self.cleaning = cleaning
    }

    /// The names nxnative gives its logs, newest first.
    static let names = ["log.txt", "log.prev.txt"]
    /// The summary's name in the zip.
    static let summaryName = "about.txt"

    static let cleanedNote = "Cleaned: the paths of the device's folders, addresses, the player's names, "
        + "identifiers, anything shaped like a key and the memory a crash writes out are left out."
    static let rawNote = "The logs are as the game wrote them."
    static let leftOutNote = "Share the log from Cartouche for all of it."

    /// The same, cleaned, as Send to Cartouche sends it: what the player
    /// wrote, the facts and the lines of the logs it keeps.
    func cleaned() -> CartoucheGameLogShare {
        guard !isCleaned else { return self }
        let clean = cleaning.cleaner()
        var cleaned = self
        cleaned.what = Self.cleaned(words, by: clean)
        cleaned.environment.facts = environment.facts.map { .init($0.name, clean($0.value)) }
        cleaned.logs = logs.map { $0.cleaned(by: clean) }
        cleaned.isCleaned = true
        return cleaned
    }

    /// What the player wrote, without the blank around it.
    var words: String {
        what.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleaned(_ text: String, by clean: (String) -> String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { clean(String($0)) }.joined(separator: "\n")
    }

    /// What the logs hold, first in the zip and in what Send to Cartouche
    /// sends: the game, its build, what the player wrote, Cartouche and the
    /// device, each log's dates and size, its crash line, and the lines
    /// nxnative marks as problems. Labels in English, as in a report.
    var summary: String {
        var lines = ["Cartouche game log, " + CartoucheReport.timestamp(date)]
        lines.append(Self.line("Game", game + (titleId.map { " (" + $0 + ")" } ?? "")))
        if let build, let described = Self.describe(build) {
            lines.append(Self.line("Build", described))
        }
        let words = self.words
        if !words.isEmpty {
            lines.append(Self.line("What happened", words))
        }
        lines.append(Self.line("Cartouche", [environment.cartouche, environment.basedOn].compactMap { $0 }.joined(separator: ", ")))
        lines.append(Self.line("iOS", environment.system))
        lines.append(Self.line("Device", environment.device))
        lines.append(Self.line("Language", environment.language))
        lines += environment.facts.map { Self.line($0.name, $0.value) }
        lines.append("")
        if logs.isEmpty {
            lines.append("No log: the game has not written one yet.")
        }
        for log in logs {
            lines.append(Self.line(log.name, Self.describe(log)))
            if let crash = log.crash {
                lines.append("    Crash: " + crash)
            }
        }
        let notable = logs.flatMap { log in log.notable.map { log.name + ": " + $0 } }
        if !notable.isEmpty {
            lines.append("")
            lines.append("Lines nxnative marks as problems, the first ones:")
            lines += notable.map { "    " + $0 }
        }
        if isCleaned || !logs.isEmpty {
            lines.append("")
            lines.append(isCleaned ? Self.cleanedNote : Self.rawNote)
        }
        return lines.joined(separator: "\n")
    }

    /// "the last session, 2026-11-13 20:41:07 +0100 to 2026-11-13 21:02:55
    /// +0100, 1,234 lines, 245.6 KB".
    static func describe(_ log: CartoucheGameLogDigest) -> String {
        var parts: [String] = [log.name == names[0] ? "the last session" : "the session before"]
        if let created = log.created {
            parts.append(CartoucheReport.timestamp(created) + (log.modified.map { " to " + CartoucheReport.timestamp($0) } ?? ""))
        } else if let modified = log.modified {
            parts.append("last written " + CartoucheReport.timestamp(modified))
        }
        parts.append(Self.count(log.lines) + (log.lines == 1 ? " line" : " lines"))
        parts.append(Self.size(log.bytes) + (log.isCut ? ", read up to \(Self.size(CartoucheGameLogDigest.maximumBytes))" : ""))
        return parts.joined(separator: ", ")
    }

    /// "1.0.0, nxnative 7bddb8c1e2f3, shader chain adec7d81d970, built
    /// 2026-11-13 12:00:00 +0100"; nil when nothing is known of it.
    static func describe(_ build: CartoucheGameBuild) -> String? {
        var parts: [String] = []
        if let version = build.version { parts.append(version) }
        if let commit = build.commit { parts.append("nxnative " + commit) }
        if let chain = build.chain { parts.append("shader chain " + chain) }
        if let built = build.builtAt { parts.append("built " + CartoucheReport.timestamp(built)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: Send to Cartouche

    /// What Send to Cartouche sends of the logs, cleaned, within LIMIT
    /// UTF-8 bytes: the summary, then each log whole if it fits, else its
    /// first lines and its last, a line saying how many are left out
    /// between them. The last session gets more room than the one before,
    /// and the end of a log more than its start: a crash, or the last lines
    /// before iOS stopped the game, are at its end.
    func excerpt(limit: Int) -> String {
        let share = cleaned()
        let summary = share.summary
        let logs = share.logs
        let room = max(limit - summary.utf8.count, 0)
        // Six tenths for the last session, and what one log does not need
        // goes to the other.
        let shares = logs.count > 1 ? [0.6, 0.4] : [1.0]
        var given = logs.indices.map { Int(Double(room) * shares[min($0, shares.count - 1)]) }
        if logs.count == 2 {
            let wanted = logs.map { Self.part(of: $0, within: Int.max).utf8.count + 2 }
            if wanted[0] < given[0] {
                given[1] += given[0] - wanted[0]
            } else if wanted[1] < given[1] {
                given[0] += given[1] - wanted[1]
            }
        }
        let parts = logs.enumerated().map { index, log in Self.part(of: log, within: given[index] - 2) }
        return ([summary] + parts).joined(separator: "\n\n")
    }

    /// LOG within ROOM bytes: its heading, then its lines, all of them, or
    /// its first and its last with what is left out between them: a
    /// quarter of the room for the start, the rest for the end, and what
    /// the end does not need for the start.
    private static func part(of log: CartoucheGameLogDigest, within room: Int) -> String {
        let heading = "--- " + log.name + ", " + describe(log) + " ---"
        let lastLines = log.lastLines
        let all = log.head + lastLines
        let complete = all.count == log.lines
        if complete {
            let text = ([heading] + all).joined(separator: "\n")
            if text.utf8.count <= room { return text }
        }
        let left = max(room - heading.utf8.count - 120, 0)
        let startPool = complete ? all : log.head
        var firsts = Self.lines(startPool, fromStart: true, within: left / 4)
        let endPool = complete ? Array(all.dropFirst(firsts.lines.count)) : lastLines
        let lasts = Self.lines(endPool, fromStart: false, within: left - firsts.bytes)
        let spare = left - firsts.bytes - lasts.bytes
        if spare > 0 {
            let between = complete ? Array(all.dropFirst(firsts.lines.count).dropLast(lasts.lines.count))
                : Array(log.head.dropFirst(firsts.lines.count))
            let more = Self.lines(between, fromStart: true, within: spare)
            firsts = (firsts.lines + more.lines, firsts.bytes + more.bytes)
        }
        let leftOut = log.lines - firsts.lines.count - lasts.lines.count
        var lines = [heading] + firsts.lines
        if leftOut > 0 {
            lines.append("--- " + count(leftOut) + (leftOut == 1 ? " line" : " lines") + " left out here. "
                         + leftOutNote + " ---")
        }
        lines += lasts.lines
        return lines.joined(separator: "\n")
    }

    /// As many of LINES as fit within ROOM bytes, from their start or
    /// their end, and the bytes they take.
    private static func lines(_ lines: [String], fromStart: Bool, within room: Int) -> (lines: [String], bytes: Int) {
        var taken: [String] = []
        var bytes = 0
        for line in fromStart ? lines : lines.reversed() {
            let size = line.utf8.count + 1
            if bytes + size > room { break }
            taken.append(line)
            bytes += size
        }
        return (fromStart ? taken : taken.reversed(), bytes)
    }

    /// The issue's title: the first line the player wrote, cleaned, else
    /// the game, Cartouche, the model and iOS.
    var title: String {
        let words = isCleaned ? self.words : Self.cleaned(self.words, by: cleaning.cleaner())
        let firstLine = words.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let title = firstLine.isEmpty
            ? "\(game) log, Cartouche \(Self.short(environment.cartouche)) on \(Self.short(environment.device)), "
                + "iOS \(Self.short(environment.system))"
            : "\(game) log: \(firstLine)"
        guard title.count > 120 else { return title }
        // The server takes 256 UTF-16 code units: emoji take several.
        var kept = ""
        for character in title {
            if kept.utf16.count + character.utf16.count > 118 || kept.count >= 119 { break }
            kept.append(character)
        }
        return kept + "…"
    }

    /// What Send to Cartouche posts to Cartouche's server, numbered ID,
    /// cleaned, within LIMIT bytes of JSON: the logs lose lines in the
    /// middle until it fits; nil when even the summary alone does not.
    func submission(id: String, limit: Int = CartoucheProblemReport.submissionLimit) -> CartoucheProblemSubmission? {
        let share = cleaned()
        var words = share.words
        if words.utf16.count > CartoucheProblemReport.submissionWhatLimit {
            var kept = ""
            for character in words {
                if kept.utf16.count + character.utf16.count >= CartoucheProblemReport.submissionWhatLimit { break }
                kept.append(character)
            }
            words = kept + "…"
        }
        let title = share.title
        var room = limit - words.utf8.count - 1_000
        for _ in 0..<12 where room > 0 {
            let made = CartoucheProblemSubmission(id: id, title: title, what: words, device: environment.device,
                                                  ios: environment.system, version: environment.cartouche,
                                                  logs: share.excerpt(limit: room))
            guard let size = try? made.json().count else { return nil }
            if size <= limit { return made }
            // JSON's escapes and the summary's length: a little less room.
            room = min(room - (size - limit), room * 9 / 10)
        }
        return nil
    }

    // MARK: The zip

    /// The zip's name: "Mario Kart World log 2026-11-13 2105.zip", without
    /// what a file's name cannot hold.
    static func fileName(game: String, date: Date, word: String = "log") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        var name = game.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if name.isEmpty || name.hasPrefix(".") { name = "Game" + name }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return name + " " + word + " " + formatter.string(from: date) + ".zip"
    }

    // MARK: Text

    /// "Name: value", a value of several lines indented under it.
    private static func line(_ name: String, _ value: String) -> String {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: true)
        return name + ": " + lines.joined(separator: "\n    ")
    }

    /// "1,234", the same in every language.
    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "245.6 KB", "1.20 MB".
    static func size(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? String(format: "%.2f MB", Double(bytes) / 1_000_000)
            : String(format: "%.1f KB", Double(bytes) / 1_000)
    }

    /// "0.12.1" of "0.12.1 (5ee6a80)".
    private static func short(_ text: String) -> String {
        text.components(separatedBy: " (").first ?? text
    }
}
