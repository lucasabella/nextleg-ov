import WidgetKit
import SwiftUI

struct NextLegEntry: TimelineEntry {
    let date: Date
}

struct NextLegProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextLegEntry {
        NextLegEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextLegEntry) -> Void) {
        completion(NextLegEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextLegEntry>) -> Void) {
        let timeline = Timeline(entries: [NextLegEntry(date: .now)], policy: .never)
        completion(timeline)
    }
}

struct NextLegWidgetView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("NextLeg", systemImage: "tram.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)

            Spacer(minLength: 4)

            Text("Hello, world!")
                .font(.title3.weight(.bold))

            Text("Your next ride starts here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct NextLegWidget: Widget {
    let kind: String = "NextLegWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextLegProvider()) { _ in
            NextLegWidgetView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("NextLeg")
        .description("A preview of your next trip widget.")
    }
}

#Preview(as: .systemSmall) {
    NextLegWidget()
} timeline: {
    NextLegEntry(date: .now)
}
