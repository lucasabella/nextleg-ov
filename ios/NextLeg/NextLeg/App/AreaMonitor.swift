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

    private override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Starts watching once location is allowed. Called at launch, so events that woke the app are handled.
    func start() {
        guard monitoring == nil, authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return }
        monitoring = Task {
            let monitor = await CLMonitor("NextLegAreas")
            self.monitor = monitor
            await Self.watchAreas(of: monitor)
            do {
                let events = await monitor.events
                for try await event in events {
                    guard let area = Area(rawValue: event.identifier) else { continue }
                    if event.state == .satisfied {
                        Self.record(area, inside: true, at: event.date)
                    } else if event.state == .unsatisfied {
                        Self.record(area, inside: false, at: event.date)
                    }
                }
            } catch {}
        }
    }

    /// Moves the areas to the picked home and work stops. The app calls this after a new stop is picked.
    func updateAreas() {
        guard let monitor else { return }
        Task { await Self.watchAreas(of: monitor) }
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
            // Without location, Auto goes back to picking the direction by the clock.
            JourneyPreferences.defaults.removeObject(forKey: JourneyPreferences.lastAreaKey)
            JourneyPreferences.defaults.removeObject(forKey: JourneyPreferences.boardedAtKey)
            WidgetCenter.shared.reloadTimelines(ofKind: JourneyPreferences.widgetKind)
        default:
            break
        }
    }

    /// Entering an area ends a ride and sets the direction. Leaving the area you were in means you boarded.
    private static func record(_ area: Area, inside: Bool, at date: Date) {
        let defaults = JourneyPreferences.defaults
        if inside {
            defaults.set(area.rawValue, forKey: JourneyPreferences.lastAreaKey)
            defaults.removeObject(forKey: JourneyPreferences.boardedAtKey)
        } else if JourneyPreferences.lastArea == area {
            defaults.set(date.timeIntervalSince1970, forKey: JourneyPreferences.boardedAtKey)
        } else {
            return
        }
        WidgetCenter.shared.reloadTimelines(ofKind: JourneyPreferences.widgetKind)
    }
}

private extension Area {
    var stop: Stop { JourneyPreferences.stop(for: self) }

    /// Home covers the home stop with room for the way there. Work is the work stop itself.
    var condition: CLMonitor.CircularGeographicCondition {
        CLMonitor.CircularGeographicCondition(
            center: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude),
            radius: self == .home ? 1_500 : 300
        )
    }
}
