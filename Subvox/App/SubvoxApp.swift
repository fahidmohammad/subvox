import SwiftUI

@main
struct SubvoxApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 680)
                .task { model.start() }
                .onDisappear { model.stop() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stop()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.stop() }
                    if phase == .active { model.start() }
                }
        }
        .windowResizability(.contentMinSize)
    }
}
