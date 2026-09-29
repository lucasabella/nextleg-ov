import SwiftUI
import WidgetKit

struct HomeView: View {
    @AppStorage(JourneyPreferences.homeKey, store: JourneyPreferences.defaults) private var home = JourneyPreferences.defaultHome
    @AppStorage(JourneyPreferences.workKey, store: JourneyPreferences.defaults) private var work = JourneyPreferences.defaultWork
    @AppStorage(JourneyPreferences.showsTripHomeKey, store: JourneyPreferences.defaults) private var showsTripHome = false
    @AppStorage(JourneyPreferences.serviceURLKey, store: JourneyPreferences.defaults) private var serviceURL = ""

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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your next journey")
                            .font(.largeTitle.bold())
                            .foregroundStyle(Palette.chalk)
                        Text("Choose the direction shown in your widget.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.steel)
                    }

                    Picker("Direction", selection: $showsTripHome.animation()) {
                        Text("To work").tag(false)
                        Text("To home").tag(true)
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
            .onChange(of: showsTripHome) { _, _ in reloadWidget() }
            .onChange(of: serviceURL) { _, _ in
                connectionState = .notChecked
                journeyMessage = nil
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
            serviceURL: $serviceURL,
            connectionState: connectionState,
            isCheckingConnection: isCheckingConnection,
            isRefreshingJourney: isRefreshingJourney,
            onCheckConnection: { Task { await checkConnection() } }
        )
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
            let snapshot = try await JourneyService().fetchJourney(at: serviceURL, direction: selectedDirection)
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

private struct JourneySettingsView: View {
    @Binding var home: String
    @Binding var work: String
    @Binding var serviceURL: String
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
