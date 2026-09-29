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
            let watched = await monitor.identifiers
            for area in Area.allCases where !watched.contains(area.rawValue) {
                // Assume outside, so turning this on at home or at work does not count as leaving.
                await monitor.add(area.condition, identifier: area.rawValue, assuming: .unsatisfied)
            }
            do {
                for try await event in monitor.events {
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
    /// Home covers Blerick station with room for the way there. Work is the Corridor bus stop in Veghel.
    var condition: CLMonitor.CircularGeographicCondition {
        switch self {
        case .home:
            CLMonitor.CircularGeographicCondition(center: CLLocationCoordinate2D(latitude: 51.37230, longitude: 6.15539), radius: 1_500)
        case .work:
            CLMonitor.CircularGeographicCondition(center: CLLocationCoordinate2D(latitude: 51.60001, longitude: 5.51907), radius: 300)
        }
    }
}
