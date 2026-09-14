import SwiftUI
import SoftphoneKit

/// Account screen until an account exists, then the dialer; a live call covers everything.
struct RootView: View {
    @Environment(CallEngine.self) private var engine

    var body: some View {
        Group {
            if engine.account == nil {
                AccountSetupView()
            } else {
                DialerView()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { engine.call != nil },
            set: { _ in }
        )) {
            CallView()
        }
        .tint(.primary)
    }
}
