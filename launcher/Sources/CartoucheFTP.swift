//
//  CartoucheFTP.swift
//  Cartouche
//
//  What Cartouche needs to talk to an FTP server of the player's, without
//  the network: the server's replies (RFC 959), the address of a passive
//  data connection (PASV, RFC 959; EPSV, RFC 2428) and the listings of a
//  folder (MLSD, RFC 3659, or LIST as Unix and Windows servers write it).
//  CartoucheStorageFTP.swift holds the connections.
//

import Foundation

/// A reply of the server: its code and its text, every line of it.
struct CartoucheFTPReply: Hashable {
    let code: Int
    let text: String

    /// 1xx: the server started and will reply again.
    var isPreliminary: Bool { (100 ..< 200).contains(code) }
    /// 2xx: done.
    var isDone: Bool { (200 ..< 300).contains(code) }
    /// 3xx: the server waits for the next command (PASS after USER, RNTO
    /// after RNFR).
    var isIntermediate: Bool { (300 ..< 400).contains(code) }

    /// Reads one reply from the start of LINES, and says how many lines it
    /// took; nil while its last line has not come.
    ///
    /// A reply of one line is "123 text"; one of several starts with
    /// "123-" and ends with a line starting with "123 ".
    static func parse(_ lines: [String]) -> (reply: CartoucheFTPReply, lines: Int)? {
        guard let first = lines.first, let code = Self.code(first) else { return nil }
        let marker = first.dropFirst(3).first
        if marker != "-" {
            return (CartoucheFTPReply(code: code, text: Self.rest(first)), 1)
        }
        var text = [Self.rest(first)]
        for index in 1 ..< max(lines.count, 1) {
            let line = lines[index]
            if Self.code(line) == code, line.dropFirst(3).first == " " || line.count == 3 {
                text.append(Self.rest(line))
                return (CartoucheFTPReply(code: code, text: text.joined(separator: "\n")), index + 1)
            }
            text.append(line.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func code(_ line: String) -> Int? {
        let digits = line.prefix(3)
        guard digits.count == 3, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    private static func rest(_ line: String) -> String {
        String(line.dropFirst(4))
    }
}

enum CartoucheFTPPassive {
    /// The port of EPSV's reply, "229 Entering Extended Passive Mode
    /// (|||6446|)".
    static func extendedPort(_ reply: CartoucheFTPReply) -> Int? {
        guard reply.code == 229,
              let open = reply.text.firstIndex(of: "("),
              let close = reply.text[open...].firstIndex(of: ")") else { return nil }
        let inside = reply.text[reply.text.index(after: open) ..< close]
        guard let delimiter = inside.first else { return nil }
        let fields = inside.split(separator: delimiter, omittingEmptySubsequences: false)
        guard fields.count >= 4, let port = Int(fields[3]), (1 ... 65535).contains(port) else { return nil }
        return port
    }

    /// The port of PASV's reply, "227 Entering Passive Mode
    /// (192,168,1,2,195,149)". Its address is left aside: the data
    /// connection goes to the server Cartouche signed in to, as a server
    /// behind a router may name an address of its own network.
    static func port(_ reply: CartoucheFTPReply) -> Int? {
        guard reply.code == 227 else { return nil }
        var numbers: [Int] = []
        var current = ""
        for character in reply.text {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else {
                if !current.isEmpty, let number = Int(current) { numbers.append(number) }
                current = ""
            }
        }
        if !current.isEmpty, let number = Int(current) { numbers.append(number) }
        guard numbers.count >= 6 else { return nil }
        let high = numbers[numbers.count - 2]
        let low = numbers[numbers.count - 1]
        guard (0 ... 255).contains(high), (0 ... 255).contains(low) else { return nil }
        let port = high * 256 + low
        return port > 0 ? port : nil
    }
}

/// A file or a folder in a folder's listing.
struct CartoucheFTPEntry: Hashable {
    let name: String
    let isFolder: Bool
    let size: UInt64
    let modified: Date?
}

enum CartoucheFTPListing {
    /// The entries of MLSD's listing, one per line: "type=file;size=12;
    /// modify=20261106194312; Name". The folder itself and its parent are
    /// left out, and so are links and other kinds.
    static func machine(_ text: String) -> [CartoucheFTPEntry] {
        var entries: [CartoucheFTPEntry] = []
        for line in lines(text) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let name = String(line[line.index(after: space)...])
            var facts: [String: String] = [:]
            for fact in line[..<space].split(separator: ";") {
                let parts = fact.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                facts[parts[0].lowercased()] = String(parts[1])
            }
            let type = facts["type"]?.lowercased() ?? ""
            guard type == "file" || type == "dir", !name.isEmpty else { continue }
            entries.append(CartoucheFTPEntry(
                name: name,
                isFolder: type == "dir",
                size: UInt64(facts["size"] ?? "") ?? 0,
                modified: facts["modify"].flatMap(date)
            ))
        }
        return entries
    }

    /// The entries of LIST's listing, as Unix servers write it
    /// ("drwxr-xr-x 2 ad staff 4096 Nov  6 19:43 Jeux") or Windows ones
    /// ("11-06-26  07:43PM       <DIR>          Jeux"). Lines of neither
    /// kind, links and the folder itself are left out; LIST gives no date
    /// Cartouche keeps.
    static func list(_ text: String) -> [CartoucheFTPEntry] {
        var entries: [CartoucheFTPEntry] = []
        for line in lines(text) {
            if let entry = unix(line) ?? windows(line), entry.name != ".", entry.name != ".." {
                entries.append(entry)
            }
        }
        return entries
    }

    private static func unix(_ line: String) -> CartoucheFTPEntry? {
        guard let kind = line.first, "-dl".contains(kind) else { return nil }
        let (fields, rest) = split(line, fields: 8)
        guard fields.count == 8, let rest, !rest.isEmpty,
              fields[0].count >= 10, let size = UInt64(fields[4]) else { return nil }
        // A link: "name -> target"; Cartouche shows neither.
        guard kind != "l" else { return nil }
        return CartoucheFTPEntry(name: rest, isFolder: kind == "d", size: kind == "d" ? 0 : size, modified: nil)
    }

    private static func windows(_ line: String) -> CartoucheFTPEntry? {
        let (fields, rest) = split(line, fields: 3)
        guard fields.count == 3, let rest, !rest.isEmpty,
              fields[0].contains("-"), fields[1].contains(":") else { return nil }
        if fields[2].uppercased() == "<DIR>" {
            return CartoucheFTPEntry(name: rest, isFolder: true, size: 0, modified: nil)
        }
        guard let size = UInt64(fields[2]) else { return nil }
        return CartoucheFTPEntry(name: rest, isFolder: false, size: size, modified: nil)
    }

    /// The first COUNT fields of LINE, split at runs of spaces, and what
    /// follows them, from its first character that is not a space, with
    /// the spaces inside it.
    private static func split(_ line: String, fields count: Int) -> ([String], String?) {
        var fields: [String] = []
        var index = line.startIndex
        while fields.count < count {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            guard index < line.endIndex else { return (fields, nil) }
            let start = index
            while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
            fields.append(String(line[start ..< index]))
        }
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        guard index < line.endIndex else { return (fields, nil) }
        return (fields, String(line[index...]))
    }

    private static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map(String.init)
    }

    private static func date(_ text: String) -> Date? {
        let digits = text.prefix(14)
        guard digits.count == 14 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(digits))
    }
}

enum CartoucheFTPPath {
    /// PATH, from the server's root, as commands name it: "/Jeux/Switch".
    /// A path with a line break in it would end the command early: it is
    /// refused.
    static func command(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        let breaks = parts.contains { part in
            part.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }
        }
        guard !breaks else { return nil }
        return "/" + parts.joined(separator: "/")
    }
}
