import SwiftUI
import SoftphoneKit

@main
struct SoftphoneApp: App {
    @State private var session = AppSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(session.engine)
                .onAppear { session.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: session.engine.enterBackground()
            case .active: session.engine.enterForeground()
            default: break
            }
        }
    }
}
