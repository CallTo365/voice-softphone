import SwiftUI
import SoftphoneKit

@main
struct SoftphoneApp: App {
    @State private var engine = CallEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
                .onAppear { engine.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: engine.enterBackground()
            case .active: engine.enterForeground()
            default: break
            }
        }
    }
}
