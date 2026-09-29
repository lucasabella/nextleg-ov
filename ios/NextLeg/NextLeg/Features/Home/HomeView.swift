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
    @ObservedObject private var areas = AreaMonitor.shared

    @State private var snapshots = JourneyPreferences.cachedSnapshots()
    @State private var connectionState: ConnectionState = .notChecked
    @State private var isCheckingConnection = false
    @State private var isRefreshingJourney = false
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
        areas.authorization == .authorizedAlways || areas.authorization == .authorizedWhenInUse
            ? "Auto shows the way to work near home, the way home near work, and follows the ride you are on."
            : "Auto shows the way to work before 12:00 and the way home after. Allow location in Settings to follow where you are."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your next journey")
                            .font(.largeTitle.bold())
                            .foregroundStyle(Palette.chalk)
                        Text(autoExplanation)
                            .font(.subheadline)
                            .foregroundStyle(Palette.steel)
                    }

                    Picker("Direction", selection: $directionMode.animation()) {
                        Text("Auto").tag(DirectionMode.auto)
                        Text("To work").tag(DirectionMode.toWork)
                        Text("To home").tag(DirectionMode.toHome)
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 12) {
                        TripWidgetView(trip: previewTrip, isMedium: true)
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .frame(height: 164)
                            .background(Palette.night, in: .rect(cornerRadius: 26))
                            .overlay {
                                RoundedRectangle(cornerRadius: 26)
                                    .strokeBorder(Palette.chalk.opacity(0.08))
                            }

                        Label(freshnessMessage, systemImage: freshnessSymbol)
                            .font(.footnote)
                            .foregroundStyle(previewTrip.freshness == .fresh ? Palette.steel : Palette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if serviceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        NavigationLink {
                            settingsView
                        } label: {
                            Label("Set up live journeys", systemImage: "arrow.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task { await refreshJourney() }
                        } label: {
                            if isRefreshingJourney {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label("Refresh journey", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isCheckingConnection || isRefreshingJourney)
                    }

                    if let journeyMessage {
                        Text(journeyMessage)
                            .font(.footnote)
                            .foregroundStyle(connectionState.isError ? Palette.signal : Palette.steel)
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(hex: 0x15191F))
            // Also runs when coming back from Settings, so a changed usual departure shows right away.
            .onAppear { Task { await refreshJourney() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        settingsView
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .onChange(of: home) { _, _ in reloadWidget() }
            .onChange(of: work) { _, _ in reloadWidget() }
            .onChange(of: directionMode) { _, _ in
                reloadWidget()
                Task { await refreshJourney() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refreshJourney() } }
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
            }
        }
        .tint(Palette.amber)
        .preferredColorScheme(.dark)
    }

    private var freshnessMessage: String {
        switch previewTrip.freshness {
        case .fresh: "Live journey · updated \(previewTrip.updated)"
        case .stale: "Saved journey · updated \(previewTrip.updated). Times may have changed."
        case .sample: "Example journey. Times and stops are fictional."
        }
    }

    private var freshnessSymbol: String {
        previewTrip.freshness == .fresh ? "checkmark.circle" : "info.circle"
    }

    private var settingsView: some View {
        JourneySettingsView(
            home: $home,
            work: $work,
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
        let requestedURL = serviceURL
        let requestedDeparture = JourneyPreferences.usualDeparture(for: requestedDirection)
        let requestedBoardedAt = JourneyPreferences.boardedAt(for: requestedDirection)
        isRefreshingJourney = true
        connectionState = .checking
        journeyMessage = nil
        defer {
            isRefreshingJourney = false
            if serviceURL != requestedURL || selectedDirection != requestedDirection ||
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
                  JourneyPreferences.usualDeparture(for: requestedDirection) == requestedDeparture,
                  JourneyPreferences.boardedAt(for: requestedDirection) == requestedBoardedAt else { return }
            snapshots[requestedDirection] = snapshot
            JourneyPreferences.cache(snapshot)
            connectionState = .connected
            switch snapshot.freshness {
            case .fresh:
                journeyMessage = "Journey updated."
            case .stale:
                journeyMessage = "The Pi returned stale data."
            case .sample:
                journeyMessage = "Pi connected, but this is fictional sample data."
            }
            reloadWidget()
        } catch {
            guard serviceURL == requestedURL, selectedDirection == requestedDirection else { return }
            markSelectedSnapshotStale()
            connectionState = .failed(error.localizedDescription)
            journeyMessage = cachedMessage
            reloadWidget()
        }
    }

    private var cachedMessage: String {
        guard let snapshot = snapshots[selectedDirection] else {
            return "Showing sample preview because no saved trip is available."
        }
        return snapshot.freshness == .sample
            ? "Showing fictional sample data because no live trip is saved."
            : "Showing the last saved trip, marked stale."
    }

    private func markSelectedSnapshotStale() {
        guard let snapshot = snapshots[selectedDirection], snapshot.freshness != .sample else { return }
        let staleSnapshot = snapshot.withFreshness(.stale)
        snapshots[selectedDirection] = staleSnapshot
        JourneyPreferences.cache(staleSnapshot)
    }

    private func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: JourneyPreferences.widgetKind)
    }
}

private struct JourneySettingsView: View {
    @Binding var home: String
    @Binding var work: String
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
                LabeledContent("Home") {
                    TextField("Station or stop", text: $home)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Work") {
                    TextField("Station or stop", text: $work)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Stops")
            } footer: {
                Text("These names appear in your journey and widget.")
            }

            Section {
                UsualDepartureRow(title: "To work", defaultTime: "07:00", time: $usualToWork)
                UsualDepartureRow(title: "To home", defaultTime: "17:00", time: $usualToHome)
            } header: {
                Text("Usual departure")
            } footer: {
                Text("Set when you leave your first stop. NextLeg shows the first journey at or after that time, today or the next day. When off, it shows the next journey.")
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
                Text("Auto shows the way to work near home and the way home near work, and follows the train or bus you take. Always lets this work while NextLeg is closed. NextLeg only checks whether you are near home or work. It keeps no history and never sends your location to the Pi.")
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
        case .checking: "Connecting to Pi…"
        case .connected: "Connected to Pi"
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
        case .notChecked: Palette.steel
        case .checking: Palette.amber
        case .connected: .green
        case .failed: Palette.signal
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
