import SwiftUI

struct MenuBarView: View {
    let services: AppServices

    var body: some View {
        Group {
            if !services.accessibilityTrusted {
                Label("Accessibility required", systemImage: "exclamationmark.triangle")

                Divider()
            }

            Button(services.preferences.isPaused ? "Resume Predictions" : "Pause Predictions") {
                services.preferences.isPaused.toggle()
            }

            Divider()

            SettingsLink {
                Label("Open Settings…", systemImage: "gearshape")
            }
        }
        .onAppear {
            services.refreshAccessibilityStatus()
        }
    }
}
