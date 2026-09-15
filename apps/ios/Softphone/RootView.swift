import SwiftUI
import SoftphoneKit

/// Enrollment until the device is enrolled (or a developer account exists), then the dialer; a live call covers everything.
struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(CallEngine.self) private var engine

    var body: some View {
        Group {
            if session.enrollment == nil && engine.account == nil {
                EnrollView()
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
