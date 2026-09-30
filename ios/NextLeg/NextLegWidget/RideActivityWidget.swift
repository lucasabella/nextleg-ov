import ActivityKit
import SwiftUI
import WidgetKit

struct RideActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideActivityView(state: context.state, isStale: context.isStale)
                .padding()
                .activityBackgroundTint(Palette.night)
                .activitySystemActionForegroundColor(Palette.chalk)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.mode.name, systemImage: context.state.mode.symbol)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.arrival ?? context.state.departure, style: .time)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RideActivityView(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                Image(systemName: context.state.mode.symbol)
            } compactTrailing: {
                Text(context.isStale || context.state.isStale ? "OLD"
                     : (context.state.arrival ?? context.state.departure).formatted(date: .omitted, time: .shortened))
            } minimal: {
                Image(systemName: context.state.mode.symbol)
            }
        }
    }
}

private struct RideActivityView: View {
    let state: RideActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("\(state.mode.name) to \(state.destination)", systemImage: state.mode.symbol)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(state.arrival == nil ? "Departs" : "Arrives")
                        .font(.caption2)
                    Text(state.arrival ?? state.departure, style: .time)
                        .font(.headline.monospacedDigit())
                }
            }
            if let nextMode = state.nextMode, let nextDeparture = state.nextDeparture, let nextDestination = state.nextDestination {
                Text("Change to \(nextMode.name.lowercased()) for \(nextDestination) at \(nextDeparture.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .lineLimit(1)
            }
            HStack {
                Text(status)
                if let platform = state.platform { Text("Platform \(platform)") }
                Spacer(minLength: 8)
                Text("Updated \(state.fetchedAt, style: .time)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let journeyStartedAt = state.journeyStartedAt {
                HStack(spacing: 4) {
                    Text("Journey")
                    Text(journeyStartedAt, style: .timer).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        if isStale || state.isStale { return "Old data" }
        switch state.status {
        case .delayed: return "+\(Int((Double(state.delaySeconds ?? 0) / 60).rounded())) min"
        case .onTime: return "On time"
        case .cancelled: return "Cancelled"
        case .skipped: return "Stop skipped"
        case .scheduled, .unknown: return "Scheduled"
        }
    }
}
