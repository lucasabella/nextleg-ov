import WidgetKit
import SwiftUI

struct NextLegEntry: TimelineEntry {
    let date: Date
    let trip: Trip
}

struct NextLegProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextLegEntry {
        NextLegEntry(date: .now, trip: .toVeghel)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextLegEntry) -> Void) {
        completion(NextLegEntry(date: .now, trip: JourneyPreferences.savedTrip))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextLegEntry>) -> Void) {
        Task {
            await refreshSavedJourney()
            let trip = JourneyPreferences.savedTrip
            var entries = [NextLegEntry(date: .now, trip: trip)]
            var reloadDate = Date.now.addingTimeInterval(15 * 60)
            if trip.freshness == .fresh {
                reloadDate = min(reloadDate, trip.fetchedAt.addingTimeInterval(20 * 60))
            }
            if let directionChange = JourneyPreferences.directionMode.nextChange(after: .now) {
                reloadDate = min(reloadDate, directionChange)
            }
            // One entry per whole minute before departure keeps the countdown current until the next
            // reload. The last one lands on the departure itself, then the widget asks for the next leg.
            if let departure = trip.departureDate, departure > .now {
                reloadDate = min(reloadDate, departure.addingTimeInterval(60))
                let firstMinute = Int(departure.timeIntervalSinceNow / 60)
                let lastMinute = max(0, Int((departure.timeIntervalSince(reloadDate) / 60).rounded(.up)))
                for minute in stride(from: firstMinute, through: lastMinute, by: -1) {
                    entries.append(NextLegEntry(date: departure.addingTimeInterval(Double(-minute * 60)), trip: trip))
                }
            }
            completion(Timeline(entries: entries, policy: .after(reloadDate)))
        }
    }

    private func refreshSavedJourney() async {
        let serviceURL = JourneyPreferences.defaults.string(forKey: JourneyPreferences.serviceURLKey) ?? ""
        guard !serviceURL.isEmpty else { return }
        let direction = JourneyPreferences.selectedDirection
        do {
            JourneyPreferences.cache(try await JourneyService().fetchJourney(
                at: serviceURL,
                direction: direction,
                usualDeparture: JourneyPreferences.usualDeparture(for: direction)
            ))
        } catch {
            guard let cached = JourneyPreferences.cachedSnapshot(for: direction), cached.freshness != .sample else { return }
            JourneyPreferences.cache(cached.withFreshness(.stale))
        }
    }
}

struct NextLegWidgetView: View {
    let entry: NextLegEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            LockScreenTripView(trip: entry.trip, date: entry.date)
                .containerBackground(.clear, for: .widget)
        case .accessoryCircular:
            DelayBadgeView(trip: entry.trip)
                .containerBackground(.clear, for: .widget)
        default:
            TripWidgetView(trip: entry.trip, isMedium: family == .systemMedium)
                .environment(\.colorScheme, .dark)
                .containerBackground(Palette.night, for: .widget)
        }
    }
}

struct NextLegWidget: Widget {
    let kind = JourneyPreferences.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextLegProvider()) { entry in
            NextLegWidgetView(entry: entry)
        }
        .configurationDisplayName("Next leg")
        .description("Your next train or bus, and whether it runs late.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

#Preview(as: .systemSmall) {
    NextLegWidget()
} timeline: {
    NextLegEntry(date: .now, trip: .toVeghel)
}

#Preview(as: .systemMedium) {
    NextLegWidget()
} timeline: {
    NextLegEntry(date: .now, trip: .toVeghel)
}

#Preview(as: .accessoryRectangular) {
    NextLegWidget()
} timeline: {
    NextLegEntry(date: .now, trip: .toVeghel)
}

#Preview(as: .accessoryCircular) {
    NextLegWidget()
} timeline: {
    NextLegEntry(date: .now, trip: .toVeghel)
}
