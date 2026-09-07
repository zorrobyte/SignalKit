import SwiftUI

@main
struct SignalKitExampleApp: App {
    @State private var services = DemoServices.shared
    @Environment(\.scenePhase) private var scenePhase

    init() { DemoServices.shared.bootstrap() }

    var body: some Scene {
        WindowGroup {
            TabView {
                ActivityTab()
                    .tabItem { Label("Activity", systemImage: "location.fill") }
                HealthTab()
                    .tabItem { Label("Health", systemImage: "heart.fill") }
                DurableTab()
                    .tabItem { Label("Durable", systemImage: "tray.full.fill") }
                LogTab()
                    .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
            }
            .environment(services)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { services.onForeground() }
        }
    }
}
