import SwiftUI
import WidgetKit

/// Settings for the saved journey. The widget on the Home Screen is the main product.
struct HomeView: View {
    @AppStorage(JourneyPreferences.homeKey, store: JourneyPreferences.defaults) private var home = JourneyPreferences.defaultHome
    @AppStorage(JourneyPreferences.workKey, store: JourneyPreferences.defaults) private var work = JourneyPreferences.defaultWork
    @AppStorage(JourneyPreferences.showsTripHomeKey, store: JourneyPreferences.defaults) private var showsTripHome = false

    // Sample times, with the names from the settings.
    private var previewTrip: Trip {
        Trip.sample(home: home, work: work, showsTripHome: showsTripHome)
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
                    Text("Preview with sample times.")
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
            }
            .navigationTitle("NextLeg")
            .onChange(of: home) { _, _ in reloadWidget() }
            .onChange(of: work) { _, _ in reloadWidget() }
            .onChange(of: showsTripHome) { _, _ in reloadWidget() }
        }
        .tint(Palette.amber)
        .preferredColorScheme(.dark)
    }

    private func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: JourneyPreferences.widgetKind)
    }
}

#Preview {
    HomeView()
}
