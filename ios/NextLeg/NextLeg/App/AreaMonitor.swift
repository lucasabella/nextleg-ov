import Combine
import CoreLocation
import WidgetKit

/// Watches whether the phone is near home or work, also while NextLeg is closed, to pick the direction
/// and to notice when you board. It only stores which area you are in or last left, and when you left it.
final class AreaMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = AreaMonitor()

    @Published private(set) var authorization: CLAuthorizationStatus
    private let manager = CLLocationManager()
    private var monitoring: Task<Void, Never>?
    private var monitor: CLMonitor?
    private var updatingLocation = false
    private var lastRideRefreshAt = Date.distantPast
    private var arrivalArea: Area?
    private var arrivalSince: Date?
    private var arrivalStartLocation: CLLocation?
    private var arrivalCheck: Task<Void, Never>?

    private override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Starts location updates and area monitoring once location is allowed.
    func start() {
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return }
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        manager.allowsBackgroundLocationUpdates = authorization == .authorizedAlways
        if !updatingLocation {
            manager.startUpdatingLocation()
            updatingLocation = true
        }
        guard monitoring == nil else { return }
        monitoring = Task {
            let monitor = await CLMonitor("NextLegAreas")
            self.monitor = monitor
            await Self.watchAreas(of: monitor)
            do {
                let events = await monitor.events
                for try await event in events {
                    guard let area = Area(rawValue: event.identifier) else { continue }
                    if event.state == .satisfied {
                        if JourneyPreferences.defaults.double(forKey: JourneyPreferences.boardedAtKey) > 0 {
                            beginArrivalCheck(in: area, at: nil)
                        } else {
                            Self.record(area, inside: true, at: event.date)
                        }
                    } else if event.state == .unsatisfied {
                        cancelArrivalCheck()
                        if Self.record(area, inside: false, at: event.date) {
                            refreshRideActivity(force: true, newBoarding: true)
                        }
                    }
                }
            } catch {}
        }
    }

    /// Moves the areas to the picked home and work stops. The app calls this after a new stop is picked.
    func updateAreas() {
        cancelArrivalCheck()
        guard let monitor else { return }
        Task { await Self.watchAreas(of: monitor) }
    }

    func appBecameActive() {
        refreshRideActivity(force: true)
    }

    /// Adds the home and work areas that are missing, and replaces both when a picked stop moved them.
    private static func watchAreas(of monitor: CLMonitor) async {
        let centers = Area.allCases.map { "\($0.stop.latitude),\($0.stop.longitude)" }.joined(separator: ";")
        let moved = JourneyPreferences.defaults.string(forKey: JourneyPreferences.watchedAreasKey) != centers
        let watched = await monitor.identifiers
        for area in Area.allCases where moved || !watched.contains(area.rawValue) {
            await monitor.remove(area.rawValue)
            // Assume outside, so turning this on at home or at work does not count as leaving.
            await monitor.add(area.condition, identifier: area.rawValue, assuming: .unsatisfied)
        }
        JourneyPreferences.defaults.set(centers, forKey: JourneyPreferences.watchedAreasKey)
    }

    func requestAccess() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        switch authorization {
        case .authorizedWhenInUse:
            // Area events while NextLeg is closed need Always. iOS asks this once.
            manager.requestAlwaysAuthorization()
            start()
        case .authorizedAlways:
            start()
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            updatingLocation = false
            // Without location, Auto goes back to picking the direction by the clock.
            JourneyPreferences.defaults.removeObject(forKey: JourneyPreferences.lastAreaKey)
            JourneyPreferences.defaults.removeObject(forKey: JourneyPreferences.boardedAtKey)
            WidgetCenter.shared.reloadTimelines(ofKind: JourneyPreferences.widgetKind)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              Date.now.timeIntervalSince(location.timestamp) < 120,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 500 else { return }

        if let area = Area.near(location) {
            if JourneyPreferences.defaults.double(forKey: JourneyPreferences.boardedAtKey) > 0 {
                if arrivalArea == area {
                    if arrivalStartLocation == nil {
                        beginArrivalCheck(in: area, at: location)
                    } else {
                        finishArrivalIfStationary(in: area, at: location)
                    }
                } else {
                    beginArrivalCheck(in: area, at: location)
                }
            } else if JourneyPreferences.lastArea != area {
                Self.record(area, inside: true, at: location.timestamp)
            }
        } else {
            cancelArrivalCheck()
        }

        refreshRideActivity()
    }

    private func beginArrivalCheck(in area: Area, at location: CLLocation?) {
        guard arrivalArea != area || arrivalStartLocation == nil else { return }
        arrivalCheck?.cancel()
        arrivalArea = area
        arrivalSince = location?.timestamp ?? .now
        arrivalStartLocation = location
        arrivalCheck = Task {
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            manager.requestLocation()
        }
    }

    private func finishArrivalIfStationary(in area: Area, at location: CLLocation) {
        guard arrivalArea == area,
              let arrivalSince,
              let arrivalStartLocation,
              location.timestamp.timeIntervalSince(arrivalSince) >= 180 else { return }

        guard location.distance(from: arrivalStartLocation) <= 100,
              location.speed < 0 || location.speed <= 1.2 else {
            cancelArrivalCheck()
            beginArrivalCheck(in: area, at: location)
            return
        }

        let wasOnRide = JourneyPreferences.defaults.double(forKey: JourneyPreferences.boardedAtKey) > 0
        _ = Self.record(area, inside: true, at: location.timestamp)
        cancelArrivalCheck()
        if wasOnRide {
            Task { await RideActivity.end() }
        }
    }

    private func cancelArrivalCheck() {
        arrivalCheck?.cancel()
        arrivalCheck = nil
        arrivalArea = nil
        arrivalSince = nil
        arrivalStartLocation = nil
    }

    private func refreshRideActivity(force: Bool = false, newBoarding: Bool = false) {
        guard JourneyPreferences.directionMode == .auto,
              let area = JourneyPreferences.lastArea,
              let boardedAt = JourneyPreferences.boardedAt(for: area.direction) else { return }
        let serviceURL = JourneyPreferences.defaults.string(forKey: JourneyPreferences.serviceURLKey) ?? ""
        guard !serviceURL.isEmpty else { return }
        guard RideActivity.isActive || Date.now.timeIntervalSince(boardedAt) <= 35 * 60 else { return }
        guard force || Date.now.timeIntervalSince(lastRideRefreshAt) >= 60 else { return }
        lastRideRefreshAt = .now

        Task {
            if newBoarding { await RideActivity.end() }
            do {
                let snapshot = try await JourneyService().fetchJourney(
                    at: serviceURL,
                    direction: area.direction,
                    usualDeparture: JourneyPreferences.usualDeparture(for: area.direction),
                    boardedAt: boardedAt
                )
                guard JourneyPreferences.boardedAt(for: area.direction) == boardedAt,
                      Self.matchesBoardedRide(snapshot, at: boardedAt) else { return }
                if RideActivity.isActive && !newBoarding {
                    await RideActivity.update(with: snapshot)
                } else {
                    guard let firstLeg = snapshot.legs.first,
                          Date.now >= (firstLeg.expectedDeparture ?? firstLeg.scheduledDeparture).addingTimeInterval(-60) else { return }
                    try await RideActivity.startAutomatically(snapshot: snapshot, legIndex: 0)
                }
            } catch {
                await RideActivity.markStale(direction: area.direction)
            }
        }
    }

    private static func matchesBoardedRide(_ snapshot: JourneySnapshot, at date: Date) -> Bool {
        guard snapshot.freshness == .fresh, let firstLeg = snapshot.legs.first else { return false }
        let departureOffset = firstLeg.scheduledDeparture.timeIntervalSince(date)
        return (-30 * 60...5 * 60).contains(departureOffset)
    }

    /// Entering an area ends a ride and sets the direction. Leaving the area you were in means you boarded.
    @discardableResult
    private static func record(_ area: Area, inside: Bool, at date: Date) -> Bool {
        let defaults = JourneyPreferences.defaults
        if inside {
            defaults.set(area.rawValue, forKey: JourneyPreferences.lastAreaKey)
            defaults.removeObject(forKey: JourneyPreferences.boardedAtKey)
        } else if JourneyPreferences.lastArea == area {
            defaults.set(date.timeIntervalSince1970, forKey: JourneyPreferences.boardedAtKey)
        } else {
            return false
        }
        WidgetCenter.shared.reloadTimelines(ofKind: JourneyPreferences.widgetKind)
        return true
    }
}

private extension Area {
    var stop: Stop { JourneyPreferences.stop(for: self) }

    var radius: CLLocationDistance { self == .home ? 1_500 : 300 }

    static func near(_ location: CLLocation) -> Area? {
        allCases.compactMap { area -> (Area, CLLocationDistance)? in
            let center = CLLocation(latitude: area.stop.latitude, longitude: area.stop.longitude)
            let distance = location.distance(from: center)
            return distance <= area.radius ? (area, distance) : nil
        }
        .min { $0.1 < $1.1 }?.0
    }

    /// Home covers the home stop with room for the way there. Work is the work stop itself.
    var condition: CLMonitor.CircularGeographicCondition {
        CLMonitor.CircularGeographicCondition(
            center: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude),
            radius: radius
        )
    }
}
