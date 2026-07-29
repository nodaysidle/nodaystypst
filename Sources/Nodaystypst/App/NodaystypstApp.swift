import SwiftUI

@main
struct NodaystypstApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        MenuBarExtra("nodaystypst", systemImage: "text.append") {
            MenuBarView(services: services)
        }
        Settings {
            SettingsView(services: services)
        }
    }
}
