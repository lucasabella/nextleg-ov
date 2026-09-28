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
        let entry = NextLegEntry(date: .now, trip: JourneyPreferences.savedTrip)
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
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
