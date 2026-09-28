import SwiftUI

enum Mode {
    case train, bus

    var name: String { self == .train ? "Train" : "Bus" }
    var symbol: String { self == .train ? "train.side.front.car" : "bus.fill" }
}

/// One direction of the saved journey. Optional fields stay empty when the provider does not supply them.
struct Trip {
    var from: String
    var to: String
    var area: String?
    var nextLeg: Mode
    var followingLeg: Mode
    var departure: String?
    var expected: String?
    var delay: Int?
    var platform: String?
    var updated: String

    /// The current area, or the start stop when the direction was chosen by hand.
    var origin: String { area ?? "From \(from)" }
    var originSymbol: String { area == nil ? "hand.tap.fill" : "location.fill" }

    var shownTime: String { expected ?? departure ?? "--:--" }
    var isDelayed: Bool { (delay ?? 0) > 0 }

    var status: String {
        guard let delay else { return "No live times" }
        return delay > 0 ? "+\(delay) min" : "On time"
    }

    var statusSymbol: String {
        guard let delay else { return "questionmark.circle" }
        return delay > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    // Fictional placeholder data.
    static let toVeghel = Trip(
        from: "Blerick", to: "Corridor, Veghel", area: nil,
        nextLeg: .train, followingLeg: .bus,
        departure: "08:14", expected: "08:19", delay: 5, platform: "3", updated: "08:10"
    )

    static let toBlerick = Trip(
        from: "Corridor, Veghel", to: "Blerick", area: nil,
        nextLeg: .bus, followingLeg: .train,
        departure: nil, expected: nil, delay: nil, platform: nil, updated: "08:10"
    )

    static func sample(home: String, work: String, showsTripHome: Bool) -> Trip {
        let trimmedHome = home.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWork = work.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHome = trimmedHome.isEmpty ? JourneyPreferences.defaultHome : trimmedHome
        let resolvedWork = trimmedWork.isEmpty ? JourneyPreferences.defaultWork : trimmedWork
        var trip = showsTripHome ? toBlerick : toVeghel
        trip.from = showsTripHome ? resolvedWork : resolvedHome
        trip.to = showsTripHome ? resolvedHome : resolvedWork
        return trip
    }
}

enum JourneyPreferences {
    static let appGroupIdentifier = "group.com.lucasabella.nextleg"
    static let widgetKind = "NextLegWidget"
    static let homeKey = "home"
    static let workKey = "work"
    static let showsTripHomeKey = "showsTripHome"
    static let defaultHome = "Blerick"
    static let defaultWork = "Corridor, Veghel"
    static let defaults = UserDefaults(suiteName: appGroupIdentifier)!

    static var savedTrip: Trip {
        Trip.sample(
            home: defaults.string(forKey: homeKey) ?? defaultHome,
            work: defaults.string(forKey: workKey) ?? defaultWork,
            showsTripHome: defaults.bool(forKey: showsTripHomeKey)
        )
    }
}

/// Split-Flap palette: a dark departure board with amber digits.
enum Palette {
    static let night = Color(hex: 0x0D0F12)
    static let graphite = Color(hex: 0x1C2027)
    static let chalk = Color(hex: 0xF2F0E9)
    static let steel = Color(hex: 0x959DA6)
    static let amber = Color(hex: 0xFFB224)
    static let signal = Color(hex: 0xFF6A55)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
