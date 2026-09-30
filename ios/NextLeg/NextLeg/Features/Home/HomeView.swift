import SwiftUI
import WidgetKit

struct HomeView: View {
    @AppStorage(JourneyPreferences.homeKey, store: JourneyPreferences.defaults) private var home = JourneyPreferences.defaultHome
    @AppStorage(JourneyPreferences.workKey, store: JourneyPreferences.defaults) private var work = JourneyPreferences.defaultWork
    @AppStorage(JourneyPreferences.directionModeKey, store: JourneyPreferences.defaults) private var directionMode = DirectionMode.auto
    @AppStorage(JourneyPreferences.serviceURLKey, store: JourneyPreferences.defaults) private var serviceURL = ""
    @AppStorage(JourneyPreferences.usualDepartureKey(for: .toVeghel), store: JourneyPreferences.defaults) private var usualToWork = ""
    @AppStorage(JourneyPreferences.usualDepartureKey(for: .toBlerick), store: JourneyPreferences.defaults) private var usualToHome = ""
    @AppStorage(JourneyPreferences.lastAreaKey, store: JourneyPreferences.defaults) private var lastArea = ""
    @AppStorage(JourneyPreferences.boardedAtKey, store: JourneyPreferences.defaults) private var boardedAt = 0.0
    @AppStorage(JourneyPreferences.stopKey(for: .home), store: JourneyPreferences.defaults) private var homeStop = Data()
    @AppStorage(JourneyPreferences.stopKey(for: .work), store: JourneyPreferences.defaults) private var workStop = Data()
    @ObservedObject private var areas = AreaMonitor.shared

    @State private var snapshots = JourneyPreferences.cachedSnapshots()
    @State private var connectionState: ConnectionState = .notChecked
    @State private var isCheckingConnection = false
    @State private var isRefreshingJourney = false
    @State private var isTrackingRide = RideActivity.isActive
    @State private var journeyMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    private var selectedDirection: JourneyDirection {
        directionMode.direction(at: .now, lastArea: Area(rawValue: lastArea))
    }

    private var previewTrip: Trip {
        let snapshot = snapshots[selectedDirection] ?? .sample(direction: selectedDirection)
        return Trip(snapshot: snapshot, home: home, work: work,
                    tracking: JourneyPreferences.boardedAt(for: selectedDirection) != nil)
    }

    private var autoExplanation: String {
        switch areas.authorization {
        case .authorizedAlways: "Auto follows your location and the ride you board."
        case .authorizedWhenInUse: "Auto follows your location while the app is open."
        default: "Auto switches at noon. Turn on location to follow your ride."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(previewTrip.phaseTitle ?? "Next departure")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(.primary)
                        Text(directionMode == .auto ? autoExplanation : "Your next train or bus, at a glance.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Direction", selection: $directionMode.animation()) {
                        Text("Auto").tag(DirectionMode.auto)
                        Text("To work").tag(DirectionMode.toWork)
                        Text("To home").tag(DirectionMode.toHome)
                    }
                    .pickerStyle(.segmented)

                    JourneyBoardCard(trip: previewTrip)

                    VStack(alignment: .leading, spacing: 10) {
                        Label(freshnessMessage, systemImage: freshnessSymbol)
                            .font(.footnote)
                            .foregroundStyle(freshnessColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if serviceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        NavigationLink {
                            settingsView
                        } label: {
                            Label("Connect a data source", systemImage: "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(AppStyle.buttonTint)
                    } else {
                        Button {
                            Task { await refreshJourney() }
                        } label: {
                            if isRefreshingJourney {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Refreshing journey…")
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                Label("Refresh journey", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(AppStyle.buttonTint)
                        .disabled(isCheckingConnection || isRefreshingJourney)
                    }
                    if isTrackingRide {
                        Button("Stop Live Activity") {
                            Task {
                                await RideActivity.end()
                                isTrackingRide = false
                            }
                        }
                    } else if let snapshot = snapshots[selectedDirection], previewTrip.freshness == .fresh {
                        HStack {
                            ForEach(snapshot.legs.indices, id: \.self) { index in
                                Button("Track \(snapshot.legs[index].mode.name.lowercased())") {
                                    Task {
                                        do {
                                            try await RideActivity.start(snapshot: snapshot, legIndex: index)
                                            isTrackingRide = true
                                        } catch {
                                            journeyMessage = error.localizedDescription
                                        }
                                    }
                                }
                                .disabled(snapshot.legs[index].status == .cancelled || snapshot.legs[index].status == .skipped)
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    if let journeyMessage {
                        Text(journeyMessage)
                            .font(.footnote)
                            .foregroundStyle(connectionState.isError ? AppStyle.alert : AppStyle.warning)
                    }
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 22)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollIndicators(.hidden)
            // Also runs when coming back from Settings, so a changed usual departure shows right away.
            .onAppear {
                isTrackingRide = RideActivity.isActive
                Task { await refreshJourney() }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("BrandMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityHidden(true)
                        Text("NextLeg")
                            .font(.headline.weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        settingsView
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .onChange(of: homeStop) { _, _ in stopsChanged() }
            .onChange(of: workStop) { _, _ in stopsChanged() }
            .onChange(of: directionMode) { _, _ in
                reloadWidget()
                Task { await refreshJourney() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    isTrackingRide = RideActivity.isActive
                    Task { await refreshJourney() }
                }
            }
            .onChange(of: usualToWork) { _, _ in reloadWidget() }
            .onChange(of: usualToHome) { _, _ in reloadWidget() }
            // Area events arrive while the app is open too; the monitor already reloads the widget.
            .onChange(of: lastArea) { _, _ in Task { await refreshJourney() } }
            .onChange(of: boardedAt) { _, _ in Task { await refreshJourney() } }
            .onChange(of: serviceURL) { _, _ in
                connectionState = .notChecked
                journeyMessage = nil
                for direction in JourneyDirection.allCases {
                    guard let snapshot = snapshots[direction], snapshot.freshness != .sample else { continue }
                    let staleSnapshot = snapshot.withFreshness(.stale)
                    snapshots[direction] = staleSnapshot
                    JourneyPreferences.cache(staleSnapshot)
                }
                reloadWidget()
                Task { await RideActivity.markStale(direction: selectedDirection) }
            }
        }
        .tint(AppStyle.accent)
    }

    private var freshnessMessage: String {
        switch previewTrip.freshness {
        case .fresh: "Live data updated at \(previewTrip.updated)."
        case .stale: "Saved data from \(previewTrip.updated). Times may have changed."
        case .sample: "Example journey. Times and stops are fictional."
        }
    }

    private var freshnessSymbol: String {
        switch previewTrip.freshness {
        case .fresh: "checkmark.circle.fill"
        case .stale: "clock.arrow.circlepath"
        case .sample: "info.circle"
        }
    }

    private var freshnessColor: Color {
        switch previewTrip.freshness {
        case .fresh: AppStyle.positive
        case .stale: AppStyle.warning
        case .sample: .secondary
        }
    }

    private var settingsView: some View {
        JourneySettingsView(
            home: home,
            work: work,
            usualToWork: $usualToWork,
            usualToHome: $usualToHome,
            lastArea: lastArea,
            boardedAt: boardedAt,
            serviceURL: $serviceURL,
            connectionState: connectionState,
            isCheckingConnection: isCheckingConnection,
            isRefreshingJourney: isRefreshingJourney,
            onCheckConnection: { Task { await checkConnection() } }
        )
    }

    private func checkConnection() async {
        let checkedURL = serviceURL
        isCheckingConnection = true
        connectionState = .checking
        journeyMessage = nil
        defer { isCheckingConnection = false }

        do {
            try await JourneyService().checkHealth(at: checkedURL)
            guard serviceURL == checkedURL else { return }
            connectionState = .connected
        } catch {
            guard serviceURL == checkedURL else { return }
            markSelectedSnapshotStale()
            connectionState = .failed(error.localizedDescription)
            journeyMessage = cachedMessage
            reloadWidget()
        }
    }

    private func refreshJourney() async {
        guard !isRefreshingJourney, !serviceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let requestedDirection = selectedDirection
        let requestedStops = [homeStop, workStop]
        let requestedURL = serviceURL
        let requestedDeparture = JourneyPreferences.usualDeparture(for: requestedDirection)
        let requestedBoardedAt = JourneyPreferences.boardedAt(for: requestedDirection)
        isRefreshingJourney = true
        connectionState = .checking
        journeyMessage = nil
        defer {
            isRefreshingJourney = false
            if serviceURL != requestedURL || selectedDirection != requestedDirection || [homeStop, workStop] != requestedStops ||
                JourneyPreferences.usualDeparture(for: requestedDirection) != requestedDeparture ||
                JourneyPreferences.boardedAt(for: requestedDirection) != requestedBoardedAt {
                Task { await refreshJourney() }
            }
        }

        do {
            let snapshot = try await JourneyService().fetchJourney(
                at: requestedURL,
                direction: requestedDirection,
                usualDeparture: requestedDeparture,
                boardedAt: requestedBoardedAt
            )
            guard serviceURL == requestedURL,
                  selectedDirection == requestedDirection,
                  [homeStop, workStop] == requestedStops,
                  JourneyPreferences.usualDeparture(for: requestedDirection) == requestedDeparture,
                  JourneyPreferences.boardedAt(for: requestedDirection) == requestedBoardedAt else { return }
            snapshots[requestedDirection] = snapshot
            JourneyPreferences.cache(snapshot)
            await RideActivity.update(with: snapshot)
            connectionState = .connected
            journeyMessage = nil
            reloadWidget()
        } catch {
            guard serviceURL == requestedURL, selectedDirection == requestedDirection else { return }
            markSelectedSnapshotStale()
            await RideActivity.markStale(direction: requestedDirection)
            connectionState = .failed(error.localizedDescription)
            journeyMessage = cachedMessage
            reloadWidget()
        }
    }

    private var cachedMessage: String {
        guard let snapshot = snapshots[selectedDirection] else {
            return "Could not refresh. No saved trip is available."
        }
        return snapshot.freshness == .sample
            ? "Could not refresh. Showing the example journey."
            : "Could not refresh. Showing saved data."
    }

    private func markSelectedSnapshotStale() {
        guard let snapshot = snapshots[selectedDirection], snapshot.freshness != .sample else { return }
        let staleSnapshot = snapshot.withFreshness(.stale)
        snapshots[selectedDirection] = staleSnapshot
        JourneyPreferences.cache(staleSnapshot)
    }

    /// Saved journeys, the last area, and a tracked ride belong to the previous stops.
    private func stopsChanged() {
        JourneyPreferences.forgetRoute()
        snapshots = [:]
        AreaMonitor.shared.updateAreas()
        reloadWidget()
        Task {
            await RideActivity.end()
            isTrackingRide = false
            await refreshJourney()
        }
    }

    private func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: JourneyPreferences.widgetKind)
    }
}

private enum AppStyle {
    static let forest = Color(hex: 0x173D30)
    static let boardText = Color(hex: 0xF1F5F2)
    static let amber = Color(hex: 0xE4AD24)
    static let accent = adaptive(light: 0x173D30, dark: 0xA2D2B1)
    static let buttonTint = adaptive(light: 0x173D30, dark: 0x286D49)
    static let positive = adaptive(light: 0x347553, dark: 0x79C893)
    static let warning = adaptive(light: 0x8A5B00, dark: 0xF0C25C)
    static let alert = Color(hex: 0xFF9B82)
    static let quietBoardText = Color(hex: 0xBDD0C5)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

private struct JourneyBoardCard: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Label(trip.phaseTitle ?? trip.nextLeg?.name ?? "No departure", systemImage: trip.nextLeg?.symbol ?? "clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppStyle.boardText.opacity(0.88))

                Spacer(minLength: 4)

                if let platform = trip.platform {
                    Text("Platform \(platform)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppStyle.forest)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppStyle.amber, in: Capsule())
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(trip.shownTime)
                    .font(.system(size: 62, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppStyle.boardText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .accessibilityLabel("\(trip.phase == .riding ? "Arrival" : "Departure") at \(trip.shownTime)")

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 5) {
                    Text(trip.status)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.trailing)
                    if (trip.isDelayed || trip.isCancelled || trip.isSkipped), let departure = trip.departure {
                        Text("Was \(departure)")
                            .font(.caption)
                            .strikethrough()
                            .foregroundStyle(AppStyle.quietBoardText)
                    }
                }
            }

            HStack(alignment: .center, spacing: 13) {
                VStack(spacing: 0) {
                    Circle()
                        .strokeBorder(AppStyle.boardText, lineWidth: 2)
                        .frame(width: 10, height: 10)
                    Rectangle()
                        .fill(AppStyle.boardText.opacity(0.45))
                        .frame(width: 1, height: 22)
                    Circle()
                        .fill(AppStyle.amber)
                        .frame(width: 10, height: 10)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    Text(trip.origin)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(trip.to)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(AppStyle.boardText)
            }

            if let followingLeg = trip.followingLeg {
                HStack(spacing: 8) {
                    Label("Then \(followingLeg.name.lowercased())", systemImage: followingLeg.symbol)
                        .foregroundStyle(AppStyle.quietBoardText)
                    Spacer(minLength: 4)
                    if let followingStatus = trip.followingStatus {
                        Text(followingStatus)
                            .foregroundStyle(AppStyle.alert)
                    }
                }
                .font(.caption.weight(.medium))
            }

            if let noticeText = trip.noticeText {
                Label(noticeText, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppStyle.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppStyle.forest, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var statusColor: Color {
        if trip.isDelayed || trip.isCancelled || trip.isSkipped { return AppStyle.alert }
        return AppStyle.quietBoardText
    }
}

private struct JourneySettingsView: View {
    let home: String
    let work: String
    @Binding var usualToWork: String
    @Binding var usualToHome: String
    let lastArea: String
    let boardedAt: Double
    @Binding var serviceURL: String
    @ObservedObject var areas = AreaMonitor.shared
    let connectionState: ConnectionState
    let isCheckingConnection: Bool
    let isRefreshingJourney: Bool
    let onCheckConnection: () -> Void

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    StopSearchView(title: "Home", serviceURL: serviceURL) { JourneyPreferences.save($0, for: .home) }
                } label: {
                    LabeledContent("Home", value: home)
                }
                NavigationLink {
                    StopSearchView(title: "Work", serviceURL: serviceURL) { JourneyPreferences.save($0, for: .work) }
                } label: {
                    LabeledContent("Work", value: work)
                }
            } header: {
                Text("Stops")
            } footer: {
                Text("Pick any station or stop in the Netherlands. NextLeg finds the fastest journey between them, direct or with one change.")
            }

            Section {
                UsualDepartureRow(title: "To work", defaultTime: "07:00", time: $usualToWork)
                UsualDepartureRow(title: "To home", defaultTime: "17:00", time: $usualToHome)
            } header: {
                Text("Usual departure")
            } footer: {
                Text("Set when you leave your first stop. NextLeg selects the first matching journey today or tomorrow. Turn it off to show the next journey.")
            }

            Section {
                LabeledContent("Location", value: locationStatus)
                if areas.authorization == .authorizedAlways || areas.authorization == .authorizedWhenInUse {
                    LabeledContent("Now", value: areaStatus)
                }
                if areas.authorization == .notDetermined {
                    Button("Use location") { areas.requestAccess() }
                } else if areas.authorization != .authorizedAlways {
                    Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
            } header: {
                Text("Auto direction")
            } footer: {
                Text("Auto shows the way to work near home and the way home near work, and follows the train or bus you take. A Live Activity starts automatically when NextLeg is open. Always lets NextLeg check your location in the background, which can use extra battery. Your location stays on this phone. NextLeg stores only which area you left and when, and never sends your location to the Pi.")
            }

            Section {
                TextField("http://nextleg.local:8080", text: $serviceURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Service address")

                Button(action: onCheckConnection) {
                    if isCheckingConnection {
                        Label("Checking connection…", systemImage: "antenna.radiowaves.left.and.right")
                    } else {
                        Label("Check connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(isCheckingConnection || isRefreshingJourney || serviceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Label(connectionState.message, systemImage: connectionState.symbol)
                    .foregroundStyle(connectionState.color)
            } header: {
                Text("Data source")
            } footer: {
                Text("Use HTTPS outside your local network. HTTP works for local addresses only.")
            }
        }
        .navigationTitle("Settings")
    }

    private var locationStatus: String {
        switch areas.authorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "Only while open"
        case .denied, .restricted: "Off"
        default: "Not set up"
        }
    }

    private var areaStatus: String {
        guard let area = Area(rawValue: lastArea) else { return "Not known yet" }
        guard boardedAt > 0 else { return "Near \(area.rawValue)" }
        return "Left \(area.rawValue) at \(Date(timeIntervalSince1970: boardedAt).formatted(date: .omitted, time: .shortened))"
    }
}

/// A switch for one direction's usual departure, with a time picker while it is on.
/// Stores the time as "HH:mm", or an empty string when off.
private struct UsualDepartureRow: View {
    let title: String
    let defaultTime: String
    @Binding var time: String

    var body: some View {
        Toggle(title, isOn: Binding {
            !time.isEmpty
        } set: { isOn in
            time = isOn ? defaultTime : ""
        }.animation())

        if !time.isEmpty {
            DatePicker("Leaves at", selection: date, displayedComponents: .hourAndMinute)
        }
    }

    private var date: Binding<Date> {
        Binding {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: parts.first ?? 0, minute: parts.last ?? 0, second: 0, of: .now) ?? .now
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            time = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
        }
    }
}

private enum ConnectionState {
    case notChecked
    case checking
    case connected
    case failed(String)

    var message: String {
        switch self {
        case .notChecked: "Connection not checked"
        case .checking: "Checking connection…"
        case .connected: "Connected to data source"
        case .failed(let reason): "Connection failed: \(reason)"
        }
    }

    var symbol: String {
        switch self {
        case .notChecked: "questionmark.circle"
        case .checking: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .notChecked: .secondary
        case .checking: AppStyle.warning
        case .connected: AppStyle.positive
        case .failed: .red
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

#Preview {
    HomeView()
}
