import Combine
import CoreLocation
import WidgetKit

/// Watches whether the phone is near home or work, also while NextLeg is closed, to pick the direction
/// and to notice when you board. It only stores which area you are in or last left, when you left it,
/// and when that turned out to be boarding.
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
    /// The journey that left the start stop around when the phone left it, to check the phone follows it.
    private var boardingCandidate: (leftAt: Date, snapshot: JourneySnapshot)?
    private var candidateRequestedAt = Date.distantPast

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
                        if JourneyPreferences.lastArea == nil {
                            // Let the first GPS fix choose between the saved home and work stops.
                            manager.requestLocation()
                        } else if JourneyPreferences.lastArea != area {
                            if Self.rideArrives(in: area) {
                                arrive(in: area, at: event.date)
                            } else {
                                beginArrivalCheck(in: area, at: nil)
                            }
                        }
                    } else if event.state == .unsatisfied {
                        cancelArrivalCheck()
                        if Self.record(area, inside: false, at: event.date) {
                            refreshRideActivity(force: true)
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
            JourneyPreferences.defaults.removeObject(forKey: JourneyPreferences.leftStopAtKey)
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

        if JourneyPreferences.lastArea == nil, let area = Area.closest(to: location) {
            Self.record(area, inside: true, at: location.timestamp)
        } else if let area = Area.near(location), area != JourneyPreferences.lastArea {
            if Self.rideArrives(in: area) {
                arrive(in: area, at: location.timestamp)
            } else if arrivalArea == area {
                if arrivalStartLocation == nil {
                    beginArrivalCheck(in: area, at: location)
                } else {
                    finishArrivalIfStationary(in: area, at: location)
                }
            } else {
                beginArrivalCheck(in: area, at: location)
            }
        } else {
            cancelArrivalCheck()
        }

        refreshRideActivity(at: location)
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

        arrive(in: area, at: location.timestamp)
    }

    /// Reaching the other stop ends the ride and turns the direction around.
    private func arrive(in area: Area, at date: Date) {
        let wasOnRide = JourneyPreferences.defaults.double(forKey: JourneyPreferences.boardedAtKey) > 0
        Self.record(area, inside: true, at: date)
        cancelArrivalCheck()
        if wasOnRide {
            Task { await RideActivity.end() }
        }
    }

    /// Reaching the other stop when the ride is due there is the arrival, also when you walk or drive on
    /// before standing still for three minutes.
    private static func rideArrives(in area: Area) -> Bool {
        guard let from = JourneyPreferences.lastArea, from != area,
              JourneyPreferences.boardedAt(for: from.direction) != nil,
              let arrival = JourneyPreferences.cachedSnapshot(for: from.direction)?.legs.last?.arrivalTime else { return false }
        return Date.now >= arrival.addingTimeInterval(-10 * 60)
    }

    private func cancelArrivalCheck() {
        arrivalCheck?.cancel()
        arrivalCheck = nil
        arrivalArea = nil
        arrivalSince = nil
        arrivalStartLocation = nil
    }

    private func refreshRideActivity(at location: CLLocation? = nil, force: Bool = false) {
        guard JourneyPreferences.directionMode == .auto,
              let area = JourneyPreferences.lastArea,
              let boardedAt = JourneyPreferences.boardedAt(for: area.direction) else {
            if JourneyPreferences.directionMode == .auto, let area = JourneyPreferences.lastArea,
               let location = location ?? manager.location {
                checkBoarding(at: location, direction: area.direction)
            }
            refreshPickedRide(force: force)
            return
        }
        let serviceURL = JourneyPreferences.defaults.string(forKey: JourneyPreferences.serviceURLKey) ?? ""
        guard !serviceURL.isEmpty else { return }
        guard RideActivity.isActive || Date.now.timeIntervalSince(boardedAt) <= 35 * 60 else { return }
        guard force || Date.now.timeIntervalSince(lastRideRefreshAt) >= 60 else { return }
        lastRideRefreshAt = .now

        Task {
            do {
                let snapshot = try await JourneyService().fetchJourney(
                    at: serviceURL,
                    direction: area.direction,
                    usualDeparture: JourneyPreferences.usualDeparture(for: area.direction),
                    boardedAt: boardedAt
                )
                guard JourneyPreferences.boardedAt(for: area.direction) == boardedAt,
                      Self.matchesBoardedRide(snapshot, at: boardedAt) else { return }
                // The widget and the arrival check use the ride the phone is on.
                JourneyPreferences.cache(snapshot)
                WidgetCenter.shared.reloadTimelines(ofKind: JourneyPreferences.widgetKind)
                if RideActivity.isActive {
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

    /// Leaving the start stop only counts as boarding once the phone follows the journey that left then,
    /// so going home from the station by bike or car does not.
    private func checkBoarding(at location: CLLocation, direction: JourneyDirection) {
        let seconds = JourneyPreferences.defaults.double(forKey: JourneyPreferences.leftStopAtKey)
        guard seconds > 0 else { return }
        let leftAt = Date(timeIntervalSince1970: seconds)
        guard Date.now.timeIntervalSince(leftAt) <= 35 * 60 else {
            JourneyPreferences.defaults.removeObject(forKey: JourneyPreferences.leftStopAtKey)
            boardingCandidate = nil
            return
        }
        if let candidate = boardingCandidate, candidate.leftAt == leftAt {
            if Self.follows(candidate.snapshot, at: location) {
                board(candidate.snapshot, leftAt: leftAt)
            }
            return
        }
        let serviceURL = JourneyPreferences.defaults.string(forKey: JourneyPreferences.serviceURLKey) ?? ""
        guard !serviceURL.isEmpty, Date.now.timeIntervalSince(candidateRequestedAt) >= 60 else { return }
        candidateRequestedAt = .now

        Task {
            guard let snapshot = try? await JourneyService().fetchJourney(
                      at: serviceURL,
                      direction: direction,
                      usualDeparture: JourneyPreferences.usualDeparture(for: direction),
                      boardedAt: leftAt
                  ),
                  JourneyPreferences.defaults.double(forKey: JourneyPreferences.leftStopAtKey) == seconds,
                  Self.matchesBoardedRide(snapshot, at: leftAt) else { return }
            boardingCandidate = (leftAt, snapshot)
            if Self.follows(snapshot, at: location) {
                board(snapshot, leftAt: leftAt)
            }
        }
    }

    private func board(_ snapshot: JourneySnapshot, leftAt: Date) {
        let defaults = JourneyPreferences.defaults
        defaults.removeObject(forKey: JourneyPreferences.leftStopAtKey)
        defaults.set(leftAt.timeIntervalSince1970, forKey: JourneyPreferences.boardedAtKey)
        boardingCandidate = nil
        lastRideRefreshAt = .now
        JourneyPreferences.cache(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: JourneyPreferences.widgetKind)
        Task {
            await RideActivity.end()
            try? await RideActivity.startAutomatically(snapshot: snapshot, legIndex: 0)
        }
    }

    /// Whether the phone is on the journey's route: within 1.5 km of the line through its stops,
    /// and at least 2 km along it from the first stop.
    private static func follows(_ snapshot: JourneySnapshot, at location: CLLocation) -> Bool {
        let points = snapshot.legs.flatMap { $0.path ?? [] }.filter { $0.count == 2 }
        // Meters east and north of the phone. Flat is exact enough at these distances.
        let metersPerDegree = 111_320.0
        let flat = points.map { point in
            ((point[1] - location.coordinate.longitude) * metersPerDegree * cos(location.coordinate.latitude * .pi / 180),
             (point[0] - location.coordinate.latitude) * metersPerDegree)
        }
        var along = 0.0
        for (start, end) in zip(flat, flat.dropFirst()) {
            let dx = end.0 - start.0
            let dy = end.1 - start.1
            let length = (dx * dx + dy * dy).squareRoot()
            // The phone is at 0,0, so the closest point of the segment is where 0,0 projects onto it.
            let t = length > 0 ? min(max(-(start.0 * dx + start.1 * dy) / (length * length), 0), 1) : 0
            let x = start.0 + t * dx
            let y = start.1 + t * dy
            if (x * x + y * y).squareRoot() <= 1_500 && along + t * length >= 2_000 { return true }
            along += length
        }
        return false
    }

    /// A ride picked in the app without a boarding from location is updated from the journeys still underway.
    private func refreshPickedRide(force: Bool) {
        guard let direction = RideActivity.trackedDirection else { return }
        let serviceURL = JourneyPreferences.defaults.string(forKey: JourneyPreferences.serviceURLKey) ?? ""
        guard !serviceURL.isEmpty, force || Date.now.timeIntervalSince(lastRideRefreshAt) >= 60 else { return }
        lastRideRefreshAt = .now

        Task {
            do {
                let journeys = try await JourneyService().fetchUnderway(at: serviceURL, direction: direction)
                for journey in journeys {
                    await RideActivity.update(with: journey)
                }
            } catch {
                await RideActivity.markStale(direction: direction)
            }
        }
    }

    private static func matchesBoardedRide(_ snapshot: JourneySnapshot, at date: Date) -> Bool {
        guard snapshot.freshness == .fresh, let firstLeg = snapshot.legs.first else { return false }
        let departureOffset = firstLeg.scheduledDeparture.timeIntervalSince(date)
        return (-30 * 60...5 * 60).contains(departureOffset)
    }

    /// Entering an area ends a ride and sets the direction. Leaving the area you were in may be boarding,
    /// which `checkBoarding` confirms once the phone follows the ride.
    @discardableResult
    private static func record(_ area: Area, inside: Bool, at date: Date) -> Bool {
        let defaults = JourneyPreferences.defaults
        if inside {
            defaults.set(area.rawValue, forKey: JourneyPreferences.lastAreaKey)
            defaults.removeObject(forKey: JourneyPreferences.boardedAtKey)
            defaults.removeObject(forKey: JourneyPreferences.leftStopAtKey)
            WidgetCenter.shared.reloadTimelines(ofKind: JourneyPreferences.widgetKind)
            return true
        }
        guard JourneyPreferences.lastArea == area, JourneyPreferences.boardedAt(for: area.direction) == nil else { return false }
        defaults.set(date.timeIntervalSince1970, forKey: JourneyPreferences.leftStopAtKey)
        return true
    }
}

private extension Area {
    var stop: Stop { JourneyPreferences.stop(for: self) }

    var radius: CLLocationDistance { self == .home ? 1_500 : 300 }

    static func near(_ location: CLLocation) -> Area? {
        closestAreas(to: location)
            .filter { $0.1 <= $0.0.radius }
            .min { $0.1 < $1.1 }?.0
    }

    static func closest(to location: CLLocation) -> Area? {
        closestAreas(to: location).min { $0.1 < $1.1 }?.0
    }

    private static func closestAreas(to location: CLLocation) -> [(Area, CLLocationDistance)] {
        allCases.compactMap { area -> (Area, CLLocationDistance)? in
            let center = CLLocation(latitude: area.stop.latitude, longitude: area.stop.longitude)
            let distance = location.distance(from: center)
            return (area, distance)
        }
    }

    /// Home covers the home stop with room for the way there. Work is the work stop itself.
    var condition: CLMonitor.CircularGeographicCondition {
        CLMonitor.CircularGeographicCondition(
            center: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude),
            radius: radius
        )
    }
}
