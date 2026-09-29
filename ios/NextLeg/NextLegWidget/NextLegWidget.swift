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
            let entry = NextLegEntry(date: .now, trip: JourneyPreferences.savedTrip)
            let timeline = Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60)))
            completion(timeline)
        }
    }

    private func refreshSavedJourney() async {
        let serviceURL = JourneyPreferences.defaults.string(forKey: JourneyPreferences.serviceURLKey) ?? ""
        guard !serviceURL.isEmpty else { return }
        let direction = JourneyPreferences.selectedDirection
        do {
            JourneyPreferences.cache(try await JourneyService().fetchJourney(at: serviceURL, direction: direction))
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
        TripWidgetView(trip: entry.trip, isMedium: family == .systemMedium)
            .environment(\.colorScheme, .dark)
            .containerBackground(Palette.night, for: .widget)
    }
}

struct NextLegWidget: Widget {
    let kind = JourneyPreferences.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextLegProvider()) { entry in
            NextLegWidgetView(entry: entry)
        }
        .configurationDisplayName("Next leg")
        .description("Your next train or bus.")
        .supportedFamilies([.systemSmall, .systemMedium])
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
