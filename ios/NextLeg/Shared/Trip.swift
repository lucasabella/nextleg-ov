import SwiftUI

enum JourneyDirection: String, Codable, CaseIterable {
    case toVeghel = "to_veghel"
    case toBlerick = "to_blerick"
}

/// The places area monitoring watches. Near home the way to work matters, near work the way home.
enum Area: String, CaseIterable {
    case home, work

    var direction: JourneyDirection { self == .home ? .toVeghel : .toBlerick }
}

/// Which direction the app and widget show. Auto follows the area the phone is in or last left.
/// Without area events it shows the way to work before noon and the way home after.
enum DirectionMode: String {
    case auto, toWork, toHome

    func direction(at date: Date, lastArea: Area?) -> JourneyDirection {
        switch self {
        case .toWork: .toVeghel
        case .toHome: .toBlerick
        case .auto: lastArea?.direction ?? (Calendar.current.component(.hour, from: date) < 12 ? .toVeghel : .toBlerick)
        }
    }

    /// When auto mode switches by the clock next, at noon or midnight. Nil when the direction does not follow the clock.
    func nextChange(after date: Date, lastArea: Area?) -> Date? {
        guard self == .auto, lastArea == nil else { return nil }
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
    case train, bus, tram, metro, ferry

    var name: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .train: "train.side.front.car"
        case .bus: "bus.fill"
        case .tram: "tram.fill"
        case .metro: "lightrail.fill"
        case .ferry: "ferry.fill"
        }
    }
}

/// A station or stop picked in Settings from the Pi's stop search. The id is its name with a rounded position,
/// which the Pi still recognises after OpenOV renumbers its stops.
struct Stop: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let modes: [Mode]
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
    /// NS disruptions and engineering works on the stretch this train leg covers.
    let notices: [JourneyNotice]?
    let scheduledArrival: Date?
    let expectedArrival: Date?

    init(
        mode: Mode,
        origin: String,
        destination: String,
        scheduledDeparture: Date,
        expectedDeparture: Date? = nil,
        scheduledArrival: Date? = nil,
        expectedArrival: Date? = nil,
        status: JourneyLegStatus,
        delaySeconds: Int? = nil,
        platform: String? = nil,
        sourceUpdatedAt: Date? = nil,
        notices: [JourneyNotice]? = nil
    ) {
        self.mode = mode
        self.origin = origin
        self.destination = destination
        self.scheduledDeparture = scheduledDeparture
        self.expectedDeparture = expectedDeparture
        self.scheduledArrival = scheduledArrival
        self.expectedArrival = expectedArrival
        self.status = status
        self.delaySeconds = delaySeconds
        self.platform = platform
        self.sourceUpdatedAt = sourceUpdatedAt
        self.notices = notices
    }

    var delayMinutes: Int? { delaySeconds.map { Int((Double($0) / 60).rounded()) } }
    var departureTime: Date { expectedDeparture ?? scheduledDeparture }
    var arrivalTime: Date? { expectedArrival ?? scheduledArrival }
}

/// An NS disruption or engineering work. The texts come from NS, in Dutch.
struct JourneyNotice: Codable, Hashable {
    let type: String
    let title: String
    let situation: String?
    let expectedDuration: String?
    let alternative: String?
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
    /// Waiting for the shown leg to depart, riding it, or arrived after the last leg.
    enum Phase { case waiting, riding, arrived }

    var from: String
    var to: String
    var area: String?
    var phase: Phase
    var nextLeg: Mode?
    var followingLeg: Mode?
    /// The shown time as scheduled: the departure while waiting, the arrival while riding.
    var departure: String?
    /// When the shown time happens: the countdown target. Nil when there is nothing to count down to.
    var departureDate: Date?
    var expected: String?
    var delayMinutes: Int?
    var platform: String?
    var updated: String
    var fetchedAt: Date
    var legStatus: JourneyLegStatus
    var freshness: JourneyFreshness
    /// The leg that needs the most attention: cancelled first, then the biggest delay, then on time.
    var worstLeg: JourneyLeg?
    /// Short problem of the second leg, like "+7 min". Nil when it runs as planned.
    var followingStatus: String?
    /// The first NS notice on the rest of the journey.
    var notice: JourneyNotice?

    /// While `tracking` the ride the phone is on, the trip shows the part of it that matters at `date`.
    init(snapshot: JourneySnapshot, home: String, work: String, at date: Date = .now, tracking: Bool = false) {
        let goesHome = snapshot.direction == .toBlerick
        let (index, phase) = tracking ? Self.progress(through: snapshot.legs, at: date) : (0, .waiting)
        let leg = snapshot.legs.indices.contains(index) ? snapshot.legs[index] : nil
        let onBoard = phase != .waiting
        let following = phase == .arrived ? nil : snapshot.legs.dropFirst(index + 1).first

        from = goesHome ? work : home
        to = goesHome ? home : work
        switch phase {
        case .riding: area = leg.map { "Arrives \($0.destination)" }
        case .arrived: area = "Arrived"
        case .waiting: area = index > 0 ? leg.map { "From \($0.origin)" } : nil
        }
        self.phase = phase
        nextLeg = leg?.mode
        followingLeg = following?.mode
        departure = (onBoard ? leg?.scheduledArrival : leg?.scheduledDeparture).map(Self.time)
        expected = (onBoard ? leg?.expectedArrival : leg?.expectedDeparture).map(Self.time)
        if let leg, leg.status != .cancelled, leg.status != .skipped, phase != .arrived {
            departureDate = onBoard ? leg.arrivalTime : leg.departureTime
        }
        if onBoard, let scheduledArrival = leg?.scheduledArrival, let expectedArrival = leg?.expectedArrival {
            delayMinutes = Int((expectedArrival.timeIntervalSince(scheduledArrival) / 60).rounded())
        } else if !onBoard {
            delayMinutes = leg?.delayMinutes
        }
        platform = onBoard ? nil : leg?.platform
        updated = Self.time(snapshot.fetchedAt)
        fetchedAt = snapshot.fetchedAt
        if onBoard, let leg {
            // On board, the arrival counts: a late departure that made up time shows as on time.
            legStatus = (delayMinutes ?? 0) >= 1 ? .delayed : leg.status == .delayed ? .onTime : leg.status
        } else {
            legStatus = leg?.status ?? .unknown
        }
        freshness = snapshot.freshness == .fresh && Date.now.timeIntervalSince(snapshot.fetchedAt) > 20 * 60
            ? .stale : snapshot.freshness
        worstLeg = snapshot.legs.max { Self.attention($0) < Self.attention($1) }
        switch following?.status {
        case .delayed: followingStatus = "+\(following?.delayMinutes ?? 0) min"
        case .cancelled: followingStatus = "Cancelled"
        case .skipped: followingStatus = "Skipped"
        default: followingStatus = nil
        }
        notice = phase == .arrived ? nil : snapshot.legs.dropFirst(index).lazy.compactMap { $0.notices?.first }.first
    }

    private static func attention(_ leg: JourneyLeg) -> Int {
        switch leg.status {
        case .cancelled, .skipped: Int.max
        case .delayed: 1_000 + (leg.delaySeconds ?? 0)
        case .onTime: 1
        case .scheduled, .unknown: 0
        }
    }

    /// Which leg the ride is at, and whether the phone waits for it, rides it, or has arrived.
    /// A leg without an arrival time counts as ridden until the next leg departs.
    private static func progress(through legs: [JourneyLeg], at date: Date) -> (Int, Phase) {
        guard !legs.isEmpty else { return (0, .waiting) }
        for (index, leg) in legs.enumerated() {
            if date < leg.departureTime { return (index, .waiting) }
            guard let arrival = leg.arrivalTime ?? legs.dropFirst(index + 1).first?.departureTime, date >= arrival else {
                return (index, .riding)
            }
        }
        return (legs.count - 1, .arrived)
    }

    /// "On train" while riding, "Arrived" at the end, nil while waiting for a departure.
    var phaseTitle: String? {
        switch phase {
        case .waiting: nil
        case .riding: nextLeg.map { "On \($0.name.lowercased())" }
        case .arrived: "Arrived"
        }
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
        case .unknown: nextLeg == nil ? "No departures" : "No live times"
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

    /// "Disruption" or "Works" when NS reports one on the route. Widgets show it instead of an on-time status.
    var noticeLabel: String? {
        notice.map { $0.type == "maintenance" ? "Works" : "Disruption" }
    }

    /// The NS notice in full: what happens, the replacement transport, and how long it lasts.
    var noticeText: String? {
        guard let notice else { return nil }
        var parts = [notice.situation ?? notice.title]
        if let alternative = notice.alternative {
            parts.append(alternative.prefix(1).uppercased() + alternative.dropFirst() + ".")
        }
        if let expectedDuration = notice.expectedDuration { parts.append(expectedDuration) }
        return parts.joined(separator: " ")
    }

    var freshnessLabel: String {
        switch freshness {
        case .fresh: "Updated at"
        case .stale: "Saved at"
        case .sample: "Example at"
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

    private nonisolated static func time(_ date: Date) -> String {
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
    static let lastAreaKey = "lastArea"
    static let boardedAtKey = "boardedAt"
    static let watchedAreasKey = "watchedAreas"
    static let defaultHome = "Blerick"
    static let defaultWork = "Corridor, Veghel"
    static let defaults = UserDefaults(suiteName: appGroupIdentifier)!
    static let defaultHomeStop = Stop(id: "Blerick|51.373|6.155", name: "Blerick",
                                      latitude: 51.37230, longitude: 6.15539, modes: [.train])
    static let defaultWorkStop = Stop(id: "Veghel, Corridor|51.600|5.519", name: "Veghel, Corridor",
                                      latitude: 51.60001, longitude: 5.51907, modes: [.bus])

    static func stopKey(for area: Area) -> String {
        "stop.\(area.rawValue)"
    }

    /// The stop picked for home or work. Until one is picked, Blerick station and the Corridor stop in Veghel.
    static func stop(for area: Area) -> Stop {
        if let data = defaults.data(forKey: stopKey(for: area)), let stop = try? JSONDecoder().decode(Stop.self, from: data) {
            return stop
        }
        return area == .home ? defaultHomeStop : defaultWorkStop
    }

    /// Saves a picked stop. Its name also becomes the home or work name the app and widget show.
    static func save(_ stop: Stop, for area: Area) {
        guard let data = try? JSONEncoder().encode(stop) else { return }
        defaults.set(data, forKey: stopKey(for: area))
        defaults.set(stop.name, forKey: area == .home ? homeKey : workKey)
    }

    /// Where a direction starts and ends.
    static func stops(for direction: JourneyDirection) -> (from: Stop, to: Stop) {
        direction == .toVeghel ? (stop(for: .home), stop(for: .work)) : (stop(for: .work), stop(for: .home))
    }

    /// Saved journeys and the last area belong to the previous stops, so picking a new stop drops them.
    static func forgetRoute() {
        for direction in JourneyDirection.allCases {
            defaults.removeObject(forKey: snapshotKey(for: direction))
        }
        defaults.removeObject(forKey: lastAreaKey)
        defaults.removeObject(forKey: boardedAtKey)
    }

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

    /// The area the phone is in or last left, from area monitoring. Nil before the first area event.
    static var lastArea: Area? {
        Area(rawValue: defaults.string(forKey: lastAreaKey) ?? "")
    }

    /// When the phone left the area this direction starts from, if that was less than three hours ago.
    /// Stored as seconds since 1970, so the app can watch it with @AppStorage.
    static func boardedAt(for direction: JourneyDirection) -> Date? {
        let seconds = defaults.double(forKey: boardedAtKey)
        guard seconds > 0, lastArea?.direction == direction else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return Date.now.timeIntervalSince(date) < 3 * 60 * 60 ? date : nil
    }

    static var selectedDirection: JourneyDirection {
        directionMode.direction(at: .now, lastArea: lastArea)
    }

    static var savedTrip: Trip { trip(at: .now) }

    static func trip(at date: Date) -> Trip {
        let direction = selectedDirection
        let snapshot = cachedSnapshot(for: direction) ?? .sample(direction: direction)
        return Trip(
            snapshot: snapshot,
            home: defaults.string(forKey: homeKey) ?? defaultHome,
            work: defaults.string(forKey: workKey) ?? defaultWork,
            at: date,
            tracking: boardedAt(for: direction) != nil
        )
    }
}

enum Palette {
    static let night = Color(hex: 0x10251E)
    static let graphite = Color(hex: 0x1B352B)
    static let chalk = Color(hex: 0xF1F5F2)
    static let steel = Color(hex: 0xB0BEB6)
    static let amber = Color(hex: 0xE4AD24)
    static let signal = Color(hex: 0xF27B61)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
