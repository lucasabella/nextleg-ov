import SwiftUI

struct HomeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tram.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.tint)

            Text("Hello, world!")
                .font(.largeTitle.weight(.bold))

            Text("Your next ride starts here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    HomeView()
}
