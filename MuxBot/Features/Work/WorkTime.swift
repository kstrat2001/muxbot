import Foundation

/// Time text for the Work tab. Takes the clock as a parameter so tests can
/// fix it.
enum WorkTime {
    /// "just now", "5 min ago", "3 h ago" today; otherwise the date and time
    /// in the user's locale.
    static func started(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if calendar.isDate(date, inSameDayAs: now) {
            if seconds < 60 { return "just now" }
            if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
            return "\(Int(seconds / 3600)) h ago"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? "\(s / 3600)h \((s % 3600) / 60)m" : "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
