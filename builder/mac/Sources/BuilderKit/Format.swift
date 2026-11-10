//
//  Format.swift
//  Cartouche Builder
//
//  Sizes, durations and dates, as the app shows them, in its language.
//

import Foundation

public enum Format {
    /// "15,8 Go", in units of 1000 bytes, as the Finder counts.
    public static func size(_ bytes: UInt64) -> String {
        let units = L10n.french ? ["o", "Ko", "Mo", "Go", "To"] : ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = unit == 0 ? 0 : value < 10 ? 2 : value < 100 ? 1 : 0
        return "\(number(value, digits: digits)) \(units[unit])"
    }

    public static func number(_ value: Double, digits: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func percent(_ fraction: Double) -> String {
        let value = Int((max(0, min(1, fraction)) * 100).rounded(.down))
        return L10n.french ? "\(value) %" : "\(value)%"
    }

    /// "1 h 16 min", "4 min 32 s", "45 s".
    public static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        if minutes > 0 { return rest > 0 && minutes < 10 ? "\(minutes) min \(rest) s" : "\(minutes) min" }
        return "\(rest) s"
    }

    /// "il y a 2 heures", "yesterday".
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return tr("just now", "à l’instant") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "10 nov. 2026 à 07:06".
    public static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "03:30", the hour of the nightly run.
    public static func time(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }
}
