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
                        Text("To \(trip.to)")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(Palette.chalk)
                            .lineLimit(2)
                        Label(trip.origin, systemImage: trip.originSymbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.steel)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if let followingLeg = trip.followingLeg {
                            HStack(spacing: 4) {
                                Label("Then \(followingLeg.name.lowercased())", systemImage: followingLeg.symbol)
                                    .foregroundStyle(Palette.steel)
                                if let followingStatus = trip.followingStatus {
                                    Text(followingStatus)
                                        .foregroundStyle(Palette.signal)
                                }
                            }
                            .font(.caption.weight(.semibold))
                        }
                        updated
                    }
                    .frame(width: 124, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    leg
                    Text("To \(trip.to)")
                        .font(.caption2.weight(.semibold))
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
                Label(trip.phaseTitle ?? nextLeg.name, systemImage: nextLeg.symbol)
                    .foregroundStyle(Palette.chalk)
            } else {
                Label("No departure", systemImage: "clock")
                    .foregroundStyle(Palette.steel)
            }
            Spacer()
            if let platform = trip.platform {
                Text("Platform \(platform)")
                    .foregroundStyle(Palette.amber)
                    .widgetAccentable()
            }
        }
        .font(.caption.weight(.semibold))
    }

    private var status: some View {
        HStack(spacing: 6) {
            if let noticeLabel = trip.noticeLabel, !(trip.isDelayed || trip.isCancelled || trip.isSkipped) {
                Label(noticeLabel, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.signal)
            } else {
                Label(trip.status, systemImage: trip.statusSymbol)
                    .foregroundStyle(trip.statusColor)
            }
            if (trip.isDelayed || trip.isCancelled || trip.isSkipped), let departure = trip.departure {
                Text("Was \(departure)").strikethrough().foregroundStyle(Palette.steel)
            }
        }
        .font(.caption.weight(.semibold))
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
            Label("To \(trip.to)", systemImage: trip.nextLeg?.symbol ?? "clock")
                .font(.caption.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The time keeps its full width. The countdown shrinks when the widget is narrow.
                Text(trip.shownTime)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .fixedSize()
                    .widgetAccentable()
                if let countdown {
                    Text(countdown)
                        .font(.caption.weight(.semibold))
                        .minimumScaleFactor(0.6)
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

    /// Short enough for the widget width: the update time only shows when no delay or NS notice needs the room.
    private var details: String {
        var parts: [String] = []
        let hasProblem = trip.isDelayed || trip.isCancelled || trip.isSkipped
        if let phaseTitle = trip.phaseTitle { parts.append(phaseTitle) }
        if hasProblem { parts.append(trip.status) }
        if let noticeLabel = trip.noticeLabel { parts.append(noticeLabel) }
        if let platform = trip.platform { parts.append("Platform \(platform)") }
        switch trip.freshness {
        case .fresh: if !hasProblem && trip.noticeLabel == nil { parts.append("Updated \(trip.updated)") }
        case .stale: parts.append("Saved data")
        case .sample: parts.append("Example")
        }
        return parts.joined(separator: ", ")
    }
}

/// One-slot Lock Screen badge with a rounded-square background.
struct DelayBadgeView: View {
    let trip: Trip

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .padding(2)

            VStack(spacing: 1) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                title
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .widgetAccentable()
                Text(caption)
                    .font(.system(size: 10, weight: .medium))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(5)
        }
        .accessibilityElement(children: .combine)
    }

    /// A delay or cancellation says more than an NS notice, so the notice only shows without one.
    private var showsNotice: Bool {
        guard trip.noticeLabel != nil else { return false }
        return ![.delayed, .cancelled, .skipped].contains(trip.worstLeg?.status)
    }

    private var symbol: String {
        if trip.freshness == .stale || showsNotice { return "exclamationmark.triangle" }
        return trip.worstLeg?.mode.symbol ?? "clock"
    }

    /// Old data still shows the last known status, with a warning symbol and caption.
    private var title: Text {
        if showsNotice { return Text("!") }
        switch trip.worstLeg?.status {
        case .delayed: return Text("+\(trip.worstLeg?.delayMinutes ?? 0)")
        case .onTime: return Text(Image(systemName: "checkmark"))
        case .cancelled, .skipped: return Text(Image(systemName: "xmark"))
        default: return Text("--")
        }
    }

    private var caption: String {
        if trip.freshness == .stale { return "Old data" }
        if trip.freshness == .sample { return "Example" }
        if showsNotice, let noticeLabel = trip.noticeLabel { return noticeLabel }
        switch trip.worstLeg?.status {
        case .delayed: return "min late"
        case .onTime: return "On time"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        default: return "No live time"
        }
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
