//
//  DiskSpace.swift
//  Cartouche Builder
//
//  A full disk, in the player's words, as the engine says it
//  (cartouche_builder/disks.py): which disk, and what is left on it, rather
//  than Cocoa's words for an error whose cause the player cannot see.
//

import Foundation

public enum DiskSpace {
    /// Whether ERROR, or one under it, is a full disk: Cocoa's "out of
    /// space" (640) or POSIX's ENOSPC (28).
    public static func isFull(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let found = current, depth < 4 {
            if found.domain == NSCocoaErrorDomain && found.code == NSFileWriteOutOfSpaceError { return true }
            if found.domain == NSPOSIXErrorDomain && found.code == Int(ENOSPC) { return true }
            current = found.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// What is left on the disk of URL, nil when it cannot be read.
    public static func free(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else { return nil }
        return Int64(capacity)
    }

    /// "0.4 GB", "12 GB": "0,4 Go" in French, as the engine says it.
    public static func amount(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1e9
        let text = gigabytes < 10 ? String(format: "%.1f", gigabytes) : String(format: "%.0f", gigabytes)
        return L10n.french ? text.replacingOccurrences(of: ".", with: ",") + " Go" : text + " GB"
    }

    /// What the app says of ERROR: for a full disk, which and what is left
    /// on it (the disk of URL, the Mac's), rather than Cocoa's words; for
    /// another error, its own.
    public static func words(for error: Error, at url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String {
        if isFull(error) { return message(free: free(at: url)) }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The player's words for the Mac's disk, full, with FREE left on it.
    public static func message(free: Int64?) -> String {
        guard let free else {
            return tr("Your Mac's disk is full. Free some room, on the Storage page for example, then try again.",
                      "Le disque du Mac est plein. Libérez de la place, par exemple dans Stockage, puis réessayez.")
        }
        let left = amount(free)
        return tr("Your Mac's disk is full (\(left) left). Free some room, on the Storage page for example, then try again.",
                  "Le disque du Mac est plein (il reste \(left)). Libérez de la place, par exemple dans Stockage, puis réessayez.")
    }
}
