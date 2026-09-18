import Intents
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
        // A tap on one of our calls in the Phone app's Recents (CallKit `includesCallsInRecents`, docs/07): iOS
        // hands the handle back as an INStartCallIntent; the same path as the dialer, caller-ID choice included.
        .onContinueUserActivity("INStartCallIntent") { activity in
            guard let intent = activity.interaction?.intent as? INStartCallIntent,
                  let number = intent.contacts?.first?.personHandle?.value, !number.isEmpty else { return }
            session.placeCall(to: number)
        }
        .tint(.primary)
    }
}
