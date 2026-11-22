import SwiftUI

@main
struct SonossoundsApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onChange(of: phase, initial: true) { _, p in
                    if p == .active { model.start(); Task { await model.load() } } else { model.stop() }
                }
        }
    }
}
