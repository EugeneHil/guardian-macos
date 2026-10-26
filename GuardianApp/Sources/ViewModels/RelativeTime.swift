import Foundation

/// Pure relative-time formatter for event rows ("just now", "12 s ago", "3 min ago", "2 h ago", "3 d ago").
enum RelativeTime {
    static func string(from date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<1: return "just now"
        case 1 ..< 60: return "\(seconds) s ago"
        case 60 ..< 3600: return "\(seconds / 60) min ago"
        case 3600 ..< 86400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86400) d ago"
        }
    }
}
