import SwiftUI
import WidgetKit

/// Settings for the saved journey. The widget on the Home Screen is the main product.
struct HomeView: View {
    @AppStorage(JourneyPreferences.homeKey, store: JourneyPreferences.defaults) private var home = JourneyPreferences.defaultHome
    @AppStorage(JourneyPreferences.workKey, store: JourneyPreferences.defaults) private var work = JourneyPreferences.defaultWork
    @AppStorage(JourneyPreferences.showsTripHomeKey, store: JourneyPreferences.defaults) private var showsTripHome = false
    @AppStorage(JourneyPreferences.serviceURLKey, store: JourneyPreferences.defaults) private var serviceURL = ""
    @AppStorage(JourneyPreferences.usualDepartureKey(for: .toVeghel), store: JourneyPreferences.defaults) private var usualToWork = ""
    @AppStorage(JourneyPreferences.usualDepartureKey(for: .toBlerick), store: JourneyPreferences.defaults) private var usualToHome = ""

    @State private var snapshots = JourneyPreferences.cachedSnapshots()
    @State private var connectionState: ConnectionState = .notChecked
    @State private var isCheckingConnection = false
    @State private var isRefreshingJourney = false
    @State private var journeyMessage: String?

    private var selectedDirection: JourneyDirection {
        showsTripHome ? .toBlerick : .toVeghel
    }

    private var previewTrip: Trip {
        let snapshot = snapshots[selectedDirection] ?? .sample(direction: selectedDirection)
        return Trip(snapshot: snapshot, home: home, work: work)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TripWidgetView(trip: previewTrip, isMedium: true)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .frame(height: 164)
                        .background(Palette.night, in: .rect(cornerRadius: 26))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } footer: {
                    Text(previewTrip.freshness == .sample
                         ? "Fictional sample data. Live transit data is not connected yet."
                         : "Saved trip shown if the Pi service is unavailable.")
                }

                Section {
                    LabeledContent {
                        TextField("Station or stop", text: $home)
                    } label: {
                        Label("Home", systemImage: "house.fill")
                    }
                    LabeledContent {
                        TextField("Station or stop", text: $work)
                    } label: {
                        Label("Work", systemImage: "briefcase.fill")
                    }
                } header: {
                    Text("Journey")
                }
                .multilineTextAlignment(.trailing)

                Section {
                    Picker("Direction", selection: $showsTripHome.animation()) {
                        Text("To work").tag(false)
                        Text("To home").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Direction")
                } footer: {
                    Text("The widget follows the direction you pick here.")
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
                    TextField("http://nextleg.local:8080", text: $serviceURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task { await checkConnection() }
                    } label: {
                        if isCheckingConnection {
                            Label("Checking connection…", systemImage: "antenna.radiowaves.left.and.right")
                        } else {
                            Label("Check connection", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                    .disabled(isCheckingConnection || isRefreshingJourney || serviceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        Task { await refreshJourney() }
                    } label: {
                        if isRefreshingJourney {
                            Label("Loading journey…", systemImage: "arrow.clockwise")
                        } else {
                            Label("Refresh journey", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isCheckingConnection || isRefreshingJourney || serviceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Label(connectionState.message, systemImage: connectionState.symbol)
                        .foregroundStyle(connectionState.color)

                    if let journeyMessage {
                        Text(journeyMessage)
                            .font(.footnote)
                            .foregroundStyle(connectionState.isError ? Palette.signal : Palette.steel)
                    }
                } header: {
                    Text("Pi service")
                } footer: {
                    Text("Use HTTPS for remote services. HTTP is limited to local network addresses.")
                }
            }
            .navigationTitle("NextLeg")
            .onChange(of: home) { _, _ in reloadWidget() }
            .onChange(of: work) { _, _ in reloadWidget() }
            .onChange(of: showsTripHome) { _, _ in reloadWidget() }
            .onChange(of: usualToWork) { _, _ in reloadWidget() }
            .onChange(of: usualToHome) { _, _ in reloadWidget() }
            .onChange(of: serviceURL) { _, _ in
                connectionState = .notChecked
                journeyMessage = nil
            }
        }
        .tint(Palette.amber)
        .preferredColorScheme(.dark)
    }

    private func checkConnection() async {
        isCheckingConnection = true
        connectionState = .checking
        journeyMessage = nil
        defer { isCheckingConnection = false }

        do {
            try await JourneyService().checkHealth(at: serviceURL)
            connectionState = .connected
        } catch {
            markSelectedSnapshotStale()
            connectionState = .failed(error.localizedDescription)
            journeyMessage = cachedMessage
            reloadWidget()
        }
    }

    private func refreshJourney() async {
        isRefreshingJourney = true
        connectionState = .checking
        journeyMessage = nil
        defer { isRefreshingJourney = false }

        do {
            let snapshot = try await JourneyService().fetchJourney(
                at: serviceURL,
                direction: selectedDirection,
                usualDeparture: JourneyPreferences.usualDeparture(for: selectedDirection)
            )
            snapshots[selectedDirection] = snapshot
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
