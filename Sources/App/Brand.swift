import AppKit
import SwiftUI

extension Color {
    /// The app icon's teal, a little brighter in dark mode for contrast.
    static let bouncer = Color(nsColor: NSColor(name: "BouncerTeal") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.24, green: 0.80, blue: 0.75, alpha: 1)  // #3DCCBF
            : NSColor(srgbRed: 0.05, green: 0.55, blue: 0.53, alpha: 1)  // #0D8C87
    })
}

/// "4s", "12m", "3h", "2d" — compact relative times for dense lists.
enum CompactRelativeTime {
    static func string(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return "now"
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
