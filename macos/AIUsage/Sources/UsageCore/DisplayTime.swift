import Foundation

public enum DisplayTime {
    public static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        formatter.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a zzz"
        return formatter.string(from: date)
    }
    public static func countdown(to date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset time passed · refresh needed" }
        if seconds < 60 { return "in <1m" }
        let minutes = Int(seconds / 60)
        if minutes >= 1440 { return "in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "in \(minutes / 60)h \(minutes % 60)m" }
        return "in \(minutes)m"
    }
}
