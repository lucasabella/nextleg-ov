import SwiftUI

/// Searches the Pi's timetable for a station or stop while you type, and hands back the one you tap.
struct StopSearchView: View {
    let title: String
    let serviceURL: String
    let onPick: (Stop) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var stops: [Stop] = []
    @State private var message: String?

    var body: some View {
        List {
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            ForEach(stops) { stop in
                Button {
                    onPick(stop)
                    dismiss()
                } label: {
                    Label(stop.name, systemImage: stop.modes.first?.symbol ?? Mode.bus.symbol)
                        .foregroundStyle(.primary)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Station or stop")
        .autocorrectionDisabled()
        .task(id: query) { await search() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func search() async {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serviceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Connect a data source first. The stop list comes from the Pi."
            return
        }
        guard typed.count >= 2 else {
            stops = []
            message = "Type at least two letters, such as \"Eindhoven\"."
            return
        }
        // Wait for a pause in typing. A new letter cancels this search and starts another.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            let found = try await JourneyService().searchStops(at: serviceURL, query: typed)
            guard !Task.isCancelled else { return }
            stops = found
            message = found.isEmpty ? "No station or stop matches \"\(typed)\"." : nil
        } catch {
            guard !Task.isCancelled else { return }
            stops = []
            message = error.localizedDescription
        }
    }
}
