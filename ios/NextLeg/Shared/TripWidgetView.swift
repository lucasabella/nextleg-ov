import SwiftUI
import WidgetKit

/// Home Screen widget, small or medium. Shared so the app can preview it.
struct TripWidgetView: View {
    var trip: Trip = .toVeghel
    var isMedium = false

    var body: some View {
        Group {
            if isMedium {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        leg
                        Spacer(minLength: 0)
                        FlapTiles(text: trip.shownTime, size: 38)
                        status.padding(.top, 2)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("→ \(trip.to.uppercased())")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(Palette.chalk)
                            .lineLimit(2)
                        Label(trip.origin.uppercased(), systemImage: trip.originSymbol)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Palette.steel)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if let followingLeg = trip.followingLeg {
                            Label("THEN \(followingLeg.name.uppercased())", systemImage: followingLeg.symbol)
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(Palette.steel)
                        }
                        updated
                    }
                    .frame(width: 124, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    leg
                    Text("→ \(trip.to.uppercased())")
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(Palette.steel)
                    Spacer(minLength: 0)
                    FlapTiles(text: trip.shownTime, size: 28)
                    status.padding(.top, 2)
                    updated
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .labelStyle(TightLabelStyle())
    }

    private var leg: some View {
        HStack {
            if let nextLeg = trip.nextLeg {
                Label(nextLeg.name.uppercased(), systemImage: nextLeg.symbol)
                    .foregroundStyle(Palette.chalk)
            } else {
                Label("NO DEPARTURE", systemImage: "clock")
                    .foregroundStyle(Palette.steel)
            }
            Spacer()
            if let platform = trip.platform {
                Text("PL \(platform)")
                    .foregroundStyle(Palette.amber)
                    .widgetAccentable()
            }
        }
        .font(.caption.weight(.heavy))
    }

    private var status: some View {
        HStack(spacing: 6) {
            Label(trip.status.uppercased(), systemImage: trip.statusSymbol)
                .foregroundStyle(trip.statusColor)
            if (trip.isDelayed || trip.isCancelled || trip.isSkipped), let departure = trip.departure {
                Text(departure).strikethrough().foregroundStyle(Palette.steel)
            }
        }
        .font(.caption.weight(.heavy))
    }

    private var updated: some View {
        Text("\(trip.freshnessLabel) \(trip.updated)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Palette.steel)
    }
}

/// Lock Screen widget. iOS draws it in one tint, so it uses text styles instead of colors.
struct LockScreenTripView: View {
    let trip: Trip
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("→ \(trip.to)", systemImage: trip.nextLeg?.symbol ?? "clock")
                .font(.caption.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(trip.shownTime)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .widgetAccentable()
                if let countdown {
                    Text(countdown)
                        .font(.caption.weight(.semibold))
                }
            }
            Text(details)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .labelStyle(TightLabelStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var countdown: String? {
        guard let departure = trip.departureDate else { return nil }
        let minutes = Int((departure.timeIntervalSince(date) / 60).rounded(.up))
        if minutes <= 0 { return "Departed" }
        return minutes < 60 ? "in \(minutes) min" : "in \(minutes / 60) h \(minutes % 60) min"
    }

    private var details: String {
        var parts: [String] = []
        if trip.isDelayed || trip.isCancelled || trip.isSkipped { parts.append(trip.status.uppercased()) }
        if let platform = trip.platform { parts.append("PL \(platform)") }
        parts.append("\(trip.freshnessLabel) \(trip.updated)")
        return parts.joined(separator: " · ")
    }
}

/// Icon and title close together, also inside a Form where labels get a wide icon column.
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

/// Departure time as split-flap tiles, one tile per digit.
struct FlapTiles: View {
    let text: String
    let size: CGFloat

    // Tinted and clear Home Screens drop colors, so the solid tiles become translucent there.
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: size * 0.08) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                if character == ":" {
                    Text(":")
                } else {
                    // Two flaps with a small gap, drawn behind the digit.
                    Text(String(character))
                        .frame(width: size * 0.95, height: size * 1.35)
                        .background {
                            VStack(spacing: max(1, size / 20)) {
                                UnevenRoundedRectangle(topLeadingRadius: size * 0.18, topTrailingRadius: size * 0.18)
                                UnevenRoundedRectangle(bottomLeadingRadius: size * 0.18, bottomTrailingRadius: size * 0.18)
                            }
                            .foregroundStyle(renderingMode == .fullColor ? Palette.graphite : Color.primary.opacity(0.14))
                        }
                }
            }
        }
        .font(.system(size: size, weight: .bold, design: .monospaced))
        .foregroundStyle(Palette.amber)
        .widgetAccentable()
    }
}
