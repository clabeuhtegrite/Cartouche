//
//  CartoucheGameLogZip.swift
//  Cartouche
//
//  The zip the share sheet shares of a game's logs (CartoucheGameLogShare):
//  about.txt, the summary, then log.txt and log.prev.txt as the game wrote
//  them. Each log is copied first, a clone that takes no room on the
//  device's storage, so that a game still writing its log behind the
//  console does not change it while it goes into the zip.
//
//  Needs Compression (CartoucheZip.swift): tested by launcher/Package.swift
//  on a Mac.
//

import Foundation

extension CartoucheGameLogShare {
    /// Writes into FOLDER, which it makes, the zip named NAME: SUMMARY as
    /// about.txt, then the files at LOGS under their own names, as they
    /// are. Returns where the zip is.
    static func writeZip(named name: String, summary: String, logs: [URL], in folder: URL) async throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let copies = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: copies, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: copies) }
        let zip = folder.appendingPathComponent(name)
        let sink = try CartoucheFileSink(zip)
        do {
            let writer = CartoucheZipWriter(sink: sink)
            try await writer.addData(summaryName, Data(summary.utf8))
            for log in logs {
                let copy = copies.appendingPathComponent(log.lastPathComponent)
                try manager.copyItem(at: log, to: copy)
                let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                try await writer.addFile(log.lastPathComponent, from: copy, date: modified ?? Date())
            }
            try await writer.finish()
            try sink.close()
        } catch {
            try? sink.close()
            try? manager.removeItem(at: zip)
            throw error
        }
        return zip
    }
}
