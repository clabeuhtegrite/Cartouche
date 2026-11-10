//
//  zipcheck: reads IPAs as Cartouche installs them from the games folder
//  (CartoucheZip.extract, launcher/Sources/CartoucheGameActions.swift):
//  the central directory, then every entry in the order it lies, decoded in
//  the reader's 8 MiB pieces with the same CartoucheInflater calls, and
//  checked against its size and CRC-32. Nothing is written: what extract
//  writes to a file goes to /dev/null through a FileHandle.
//
//      swiftc -O -o zipcheck main.swift CartoucheZip.swift
//      ./zipcheck list <ipa>...      the central directory and Info.plist
//      ./zipcheck verify <ipa>...    every byte
//

import Darwin
import Foundation

func field16(_ data: Data, _ index: Int) -> UInt64 {
    UInt64(data[data.startIndex + index]) | UInt64(data[data.startIndex + index + 1]) << 8
}

func field32(_ data: Data, _ index: Int) -> UInt32 {
    UInt32(field16(data, index)) | UInt32(field16(data, index + 2)) << 16
}

func gib(_ bytes: UInt64) -> String {
    String(format: "%.2f GiB", Double(bytes) / 1_073_741_824)
}

func mib(_ bytes: Int64) -> String {
    String(format: "%.0f MiB", Double(bytes) / 1_048_576)
}

/// What the system counts against the process, as iOS does.
func footprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}

func say(_ text: String) {
    print(text)
    fflush(stdout)
}

func isInfoPlist(_ entry: CartoucheZipEntry) -> Bool {
    let parts = entry.name.split(separator: "/")
    return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
}

/// The central directory, what Cartouche would refuse in it, and the app's
/// Info.plist, as the games list reads it.
func list(_ path: String) async -> Bool {
    say("== list \(path)")
    do {
        let source = try CartoucheFileSource(URL(fileURLWithPath: path))
        let entries = try await CartoucheZip.entries(of: source)
        var folders = 0, links = 0, storedCount = 0, deflatedCount = 0
        var storedBytes: UInt64 = 0, deflatedBytes: UInt64 = 0, deflatedIn: UInt64 = 0
        var zip64 = source.size >= 0xFFFF_FFFF
        var refused: [String] = []
        for entry in entries {
            if CartoucheZip.safePath(entry.name) == nil { refused.append("\(entry.name): would land outside the folder") }
            if entry.size >= 0xFFFF_FFFF || entry.compressedSize >= 0xFFFF_FFFF || entry.localHeaderOffset >= 0xFFFF_FFFF {
                zip64 = true
            }
            if entry.isDirectory {
                folders += 1
            } else if entry.isSymlink {
                links += 1
            } else if entry.method == 8 {
                deflatedCount += 1
                deflatedBytes += entry.size
                deflatedIn += entry.compressedSize
            } else {
                storedCount += 1
                storedBytes += entry.size
            }
        }
        say("  archive \(gib(source.size)), \(entries.count) entries: \(folders) folders, \(links) links, "
            + "\(storedCount) files stored (\(gib(storedBytes))), \(deflatedCount) deflated (\(gib(deflatedBytes)) in \(gib(deflatedIn)))"
            + (zip64 ? ", Zip64" : ""))
        let largest = entries.filter { $0.method == 8 && !$0.isDirectory }.sorted { $0.compressedSize > $1.compressedSize }
        for entry in largest.prefix(3) {
            say("  deflated: \(entry.name), \(gib(entry.size)) in \(gib(entry.compressedSize))")
        }
        for line in refused.prefix(10) {
            say("  REFUSED: \(line)")
        }
        guard let entry = entries.first(where: isInfoPlist) else {
            say("  REFUSED: no Payload/<app>.app/Info.plist")
            return false
        }
        let data = try await CartoucheZip.data(of: entry, in: source, limit: 4 << 20)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            say("  REFUSED: the Info.plist is not a dictionary")
            return false
        }
        let name = info["CFBundleDisplayName"] ?? info["CFBundleName"] ?? "?"
        say("  app: \(info["CFBundleIdentifier"] ?? "?"), \(name), \(info["CFBundleShortVersionString"] ?? "?"), "
            + "DMCommit \(info["DMCommit"] ?? "-")")
        return refused.isEmpty
    } catch {
        say("  REFUSED: \(error.localizedDescription)")
        return false
    }
}

/// Every entry, as extract reads and checks it.
func verify(_ path: String) async -> Bool {
    say("== verify \(path)")
    let started = Date()
    do {
        let source = try CartoucheFileSource(URL(fileURLWithPath: path))
        let entries = try await CartoucheZip.entries(of: source)
        let ordered = entries.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        let total = ordered.reduce(UInt64(0)) { $0 + $1.size }
        let reader = CartoucheSequentialReader(source)
        let sink = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer { try? sink.close() }
        var done: UInt64 = 0
        var nextReport: UInt64 = 2 << 30
        var failures: [String] = []
        var links: [(path: String, target: String)] = []
        let baseFootprint = footprint()
        var peakFootprint = baseFootprint
        say("  \(entries.count) entries, \(gib(total)) to unpack")

        for entry in ordered {
            guard let relative = CartoucheZip.safePath(entry.name) else {
                failures.append("\(entry.name) would land outside the folder")
                continue
            }
            if entry.isDirectory { continue }
            do {
                try await reader.seek(to: entry.localHeaderOffset)
                let header = try await reader.read(exactly: 30)
                guard field32(header, 0) == CartoucheZip.localSignature else {
                    throw CartoucheZipError("\(entry.name): its local header is damaged")
                }
                try await reader.skip(field16(header, 26) + field16(header, 28))

                if entry.isSymlink {
                    let target = try await reader.read(exactly: Int(min(entry.compressedSize, 4096)))
                    guard entry.method == 0, let text = String(data: target, encoding: .utf8),
                          CartoucheCRC32.of(target) == entry.crc else {
                        throw CartoucheZipError("\(entry.name): its link is damaged")
                    }
                    links.append((relative, text))
                    done += entry.size
                    continue
                }

                var check = CartoucheCRC32()
                var written: UInt64 = 0
                var inflater: CartoucheInflater?
                if entry.method == 8 {
                    inflater = try CartoucheInflater()
                }
                var left = entry.compressedSize
                while left > 0 {
                    let chunk = try await reader.read(upTo: Int(min(left, UInt64(CartoucheSequentialReader.chunk))))
                    guard !chunk.isEmpty else { throw CartoucheZipError("the archive ended early, in \(entry.name)") }
                    left -= UInt64(chunk.count)
                    let before = written
                    if let inflater {
                        try inflater.feed(chunk, last: left == 0) { output in
                            check.update(output)
                            try sink.write(contentsOf: output)
                            written += UInt64(output.count)
                        }
                    } else {
                        check.update(chunk)
                        try sink.write(contentsOf: chunk)
                        written += UInt64(chunk.count)
                    }
                    done += written - before
                    if done >= nextReport {
                        let now = footprint()
                        peakFootprint = max(peakFootprint, now)
                        let seconds = Date().timeIntervalSince(started)
                        say(String(format: "  %@ of %@, %.0f MB/s, footprint %@",
                                   gib(done), gib(total), Double(done) / 1_000_000 / max(seconds, 0.001), mib(now)))
                        nextReport += 2 << 30
                    }
                }
                if let inflater, !inflater.finished {
                    throw CartoucheZipError("\(entry.name) is damaged (its deflated data ends early): "
                                            + "\(written) of \(entry.size) bytes came out")
                }
                guard written == entry.size, check.value == entry.crc else {
                    throw CartoucheZipError("\(entry.name) is damaged (its size or CRC-32 does not match): "
                                            + "\(written) of \(entry.size) bytes, CRC-32 \(String(check.value, radix: 16)) "
                                            + "for \(String(entry.crc, radix: 16))")
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        // Links last, each inside the folder, as extract checks them.
        let root = URL(fileURLWithPath: "/CartoucheInstall", isDirectory: true)
        for link in links {
            let place = root.appendingPathComponent(link.path).deletingLastPathComponent()
            let resolved = URL(fileURLWithPath: link.target, relativeTo: place).standardizedFileURL.path
            if link.target.hasPrefix("/") || !(resolved == root.path || resolved.hasPrefix(root.path + "/")) {
                failures.append("\(link.path) links outside the folder, to \(link.target)")
            }
        }

        peakFootprint = max(peakFootprint, footprint())
        let seconds = Date().timeIntervalSince(started)
        say(String(format: "  %@ in %.0f s (%.0f MB/s), %d links, footprint %@ at the start, %@ at most",
                   gib(done), seconds, Double(done) / 1_000_000 / max(seconds, 0.001), links.count,
                   mib(baseFootprint), mib(peakFootprint)))
        for failure in failures.prefix(20) {
            say("  FAILED: \(failure)")
        }
        if failures.count > 20 { say("  ... and \(failures.count - 20) more") }
        say(failures.isEmpty ? "  OK: Cartouche reads every entry" : "  \(failures.count) entries refused")
        return failures.isEmpty
    } catch {
        say("  FAILED: \(error.localizedDescription)")
        return false
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first, mode == "list" || mode == "verify", arguments.count > 1 else {
    say("usage: zipcheck list|verify <ipa>...")
    exit(2)
}
var allGood = true
for path in arguments.dropFirst() {
    let good: Bool
    if mode == "list" {
        good = await list(path)
    } else {
        good = await verify(path)
    }
    allGood = allGood && good
}
exit(allGood ? 0 : 1)
