import SwiftUI

enum JourneyDirection: String, Codable, CaseIterable {
    case toVeghel = "to_veghel"
    case toBlerick = "to_blerick"
}

/// Which direction the app and widget show. Auto shows the way to work before noon and the way home after.
enum DirectionMode: String {
    case auto, toWork, toHome

    func direction(at date: Date) -> JourneyDirection {
        switch self {
        case .toWork: .toVeghel
        case .toHome: .toBlerick
        case .auto: Calendar.current.component(.hour, from: date) < 12 ? .toVeghel : .toBlerick
        }
    }

    /// When auto mode switches next, at noon or midnight. Nil for a fixed direction.
    func nextChange(after date: Date) -> Date? {
        guard self == .auto else { return nil }
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)!
        return date < noon ? noon : calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }
}

enum JourneyFreshness: String, Codable {
    case fresh
    case stale
    case sample
}

enum Mode: String, Codable {
    case train, bus

    var name: String { self == .train ? "Train" : "Bus" }
    var symbol: String { self == .train ? "train.side.front.car" : "bus.fill" }
}

enum JourneyLegStatus: String, Codable {
    case scheduled
    case onTime = "on_time"
    case delayed
    case cancelled
    case skipped
    case unknown
}

struct JourneyLeg: Codable {
    let mode: Mode
    let origin: String
    let destination: String
    let scheduledDeparture: Date
    let expectedDeparture: Date?
    let status: JourneyLegStatus
    let delaySeconds: Int?
    let platform: String?
    let sourceUpdatedAt: Date?

    init(
        mode: Mode,
        origin: String,
        destination: String,
        scheduledDeparture: Date,
        expectedDeparture: Date? = nil,
        status: JourneyLegStatus,
        delaySeconds: Int? = nil,
        platform: String? = nil,
        sourceUpdatedAt: Date? = nil
    ) {
        self.mode = mode
        self.origin = origin
        self.destination = destination
        self.scheduledDeparture = scheduledDeparture
        self.expectedDeparture = expectedDeparture
        self.status = status
        self.delaySeconds = delaySeconds
        self.platform = platform
        self.sourceUpdatedAt = sourceUpdatedAt
    }
}

struct JourneySnapshot: Codable {
    let direction: JourneyDirection
    let fetchedAt: Date
    let freshness: JourneyFreshness
    let legs: [JourneyLeg]

    func withFreshness(_ freshness: JourneyFreshness) -> JourneySnapshot {
        JourneySnapshot(direction: direction, fetchedAt: fetchedAt, freshness: freshness, legs: legs)
    }

    static func sample(direction: JourneyDirection) -> JourneySnapshot {
        switch direction {
        case .toVeghel:
            JourneySnapshot(
                direction: direction,
                fetchedAt: date("2026-09-28T06:10:00Z"),
                freshness: .sample,
                legs: [
                    JourneyLeg(
                        mode: .train,
                        origin: "Sample origin",
                        destination: "Sample transfer",
                        scheduledDeparture: date("2026-09-28T06:14:00Z"),
                        expectedDeparture: date("2026-09-28T06:19:00Z"),
                        status: .delayed,
                        delaySeconds: 300,
                        platform: "3",
                        sourceUpdatedAt: date("2026-09-28T06:09:00Z")
                    ),
                    JourneyLeg(
                        mode: .bus,
                        origin: "Sample transfer",
                        destination: "Sample destination",
                        scheduledDeparture: date("2026-09-28T06:42:00Z"),
                        status: .scheduled
                    )
                ]
            )
        case .toBlerick:
            JourneySnapshot(
                direction: direction,
                fetchedAt: date("2026-09-28T12:10:00Z"),
                freshness: .sample,
                legs: [
                    JourneyLeg(
                        mode: .bus,
                        origin: "Sample destination",
                        destination: "Sample transfer",
                        scheduledDeparture: date("2026-09-28T14:10:00Z"),
                        status: .scheduled
                    ),
                    JourneyLeg(
                        mode: .train,
                        origin: "Sample transfer",
                        destination: "Sample origin",
                        scheduledDeparture: date("2026-09-28T14:44:00Z"),
                        status: .scheduled
                    )
                ]
            )
        }
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

enum JourneyJSON {
    static func decode(_ data: Data) throws -> JourneySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JourneySnapshot.self, from: data)
    }

    static func encode(_ snapshot: JourneySnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }
}

struct Trip {
    var from: String
    var to: String
    var area: String?
    var nextLeg: Mode?
    var followingLeg: Mode?
    var departure: String?
    var departureDate: Date?
    var expected: String?
    var delayMinutes: Int?
    var platform: String?
    var updated: String
    var legStatus: JourneyLegStatus
    var freshness: JourneyFreshness

    init(snapshot: JourneySnapshot, home: String, work: String) {
        let goesHome = snapshot.direction == .toBlerick
        let firstLeg = snapshot.legs.first
        let secondLeg = snapshot.legs.dropFirst().first

        from = goesHome ? work : home
        to = goesHome ? home : work
        area = nil
        nextLeg = firstLeg?.mode
        followingLeg = secondLeg?.mode
        departure = firstLeg.map { Self.time($0.scheduledDeparture) }
        if let firstLeg, firstLeg.status != .cancelled, firstLeg.status != .skipped {
            departureDate = firstLeg.expectedDeparture ?? firstLeg.scheduledDeparture
        }
        if let expectedDeparture = firstLeg?.expectedDeparture {
            expected = Self.time(expectedDeparture)
        } else {
            expected = nil
        }
        delayMinutes = firstLeg?.delaySeconds.map { Int((Double($0) / 60).rounded()) }
        platform = firstLeg?.platform
        updated = Self.time(snapshot.fetchedAt)
        legStatus = firstLeg?.status ?? .unknown
        freshness = snapshot.freshness
    }

    var origin: String { area ?? "From \(from)" }
    var originSymbol: String { area == nil ? "hand.tap.fill" : "location.fill" }
    var shownTime: String { isCancelled || isSkipped ? "--:--" : expected ?? departure ?? "--:--" }
    var isDelayed: Bool { legStatus == .delayed }
    var isCancelled: Bool { legStatus == .cancelled }
    var isSkipped: Bool { legStatus == .skipped }

    var status: String {
        switch legStatus {
        case .scheduled: "Scheduled"
        case .onTime: "On time"
        case .delayed:
            delayMinutes.map { "\($0 > 0 ? "+" : "")\($0) min" } ?? "Delayed"
        case .cancelled: "Cancelled"
        case .skipped: "Stop skipped"
        case .unknown: "No live times"
        }
    }

    var statusSymbol: String {
        switch legStatus {
        case .scheduled: "clock"
        case .onTime: "checkmark.circle.fill"
        case .delayed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        case .skipped: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var statusColor: Color {
        isDelayed || isCancelled || isSkipped ? Palette.signal : Palette.steel
    }

    var freshnessLabel: String {
        switch freshness {
        case .fresh: "UPDATED"
        case .stale: "STALE · UPDATED"
        case .sample: "SAMPLE · UPDATED"
        }
    }

    static var toVeghel: Trip {
        Trip(snapshot: .sample(direction: .toVeghel), home: JourneyPreferences.defaultHome, work: JourneyPreferences.defaultWork)
    }

    static var toBlerick: Trip {
        Trip(snapshot: .sample(direction: .toBlerick), home: JourneyPreferences.defaultHome, work: JourneyPreferences.defaultWork)
    }

    static func sample(home: String, work: String, showsTripHome: Bool) -> Trip {
        let trimmedHome = home.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWork = work.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHome = trimmedHome.isEmpty ? JourneyPreferences.defaultHome : trimmedHome
        let resolvedWork = trimmedWork.isEmpty ? JourneyPreferences.defaultWork : trimmedWork
        let direction: JourneyDirection = showsTripHome ? .toBlerick : .toVeghel
        return Trip(snapshot: .sample(direction: direction), home: resolvedHome, work: resolvedWork)
    }

    private static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }
}

enum JourneyPreferences {
    static let appGroupIdentifier = "group.com.lucasabella.nextleg"
    static let widgetKind = "NextLegWidget"
    static let homeKey = "home"
    static let workKey = "work"
    static let directionModeKey = "directionMode"
    static let serviceURLKey = "serviceURL"
    static let defaultHome = "Blerick"
    static let defaultWork = "Corridor, Veghel"
    static let defaults = UserDefaults(suiteName: appGroupIdentifier)!

    private static func snapshotKey(for direction: JourneyDirection) -> String {
        "journeySnapshot.\(direction.rawValue)"
    }

    static func cachedSnapshot(for direction: JourneyDirection) -> JourneySnapshot? {
        guard let data = defaults.data(forKey: snapshotKey(for: direction)) else { return nil }
        return try? JourneyJSON.decode(data)
    }

    static func cachedSnapshots() -> [JourneyDirection: JourneySnapshot] {
        Dictionary(uniqueKeysWithValues: JourneyDirection.allCases.compactMap { direction in
            cachedSnapshot(for: direction).map { (direction, $0) }
        })
    }

    static func usualDepartureKey(for direction: JourneyDirection) -> String {
        "usualDeparture.\(direction.rawValue)"
    }

    /// The usual departure as "HH:mm", or nil to follow the next journey.
    static func usualDeparture(for direction: JourneyDirection) -> String? {
        let value = defaults.string(forKey: usualDepartureKey(for: direction)) ?? ""
        return value.isEmpty ? nil : value
    }

    static func cache(_ snapshot: JourneySnapshot) {
        guard let data = try? JourneyJSON.encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey(for: snapshot.direction))
    }

    static var directionMode: DirectionMode {
        DirectionMode(rawValue: defaults.string(forKey: directionModeKey) ?? "") ?? .auto
    }

    static var selectedDirection: JourneyDirection {
        directionMode.direction(at: .now)
    }

    static var savedTrip: Trip {
        let direction = selectedDirection
        let snapshot = cachedSnapshot(for: direction) ?? .sample(direction: direction)
        return Trip(
            snapshot: snapshot,
            home: defaults.string(forKey: homeKey) ?? defaultHome,
            work: defaults.string(forKey: workKey) ?? defaultWork
        )
    }
}

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
