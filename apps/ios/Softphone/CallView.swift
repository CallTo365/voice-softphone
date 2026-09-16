import SwiftUI
import SoftphoneKit

/// The in-call screen for phase 0 (foreground only). Phase 1 keeps this screen and adds CallKit
/// behind it; the buttons then go through CallKit actions instead of calling the engine directly.
struct CallView: View {
    @Environment(AppSession.self) private var session
    @Environment(CallEngine.self) private var engine
    @State private var showKeypad = false
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 8) {
                Text(engine.call?.displayName ?? "")
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let media = engine.call?.media {
                    Text(media.summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            Spacer()

            if let call = engine.call, call.phase.isLive {
                if call.phase == .incoming {
                    HStack(spacing: 64) {
                        RoundButton(symbol: "phone.down.fill", label: "Decline", tint: .red) { engine.decline() }
                        RoundButton(symbol: "phone.fill", label: "Accept", tint: .green) { engine.accept() }
                    }
                } else {
                    HStack(spacing: 40) {
                        ToggleButton(symbol: "mic.slash.fill", label: "Mute", isOn: call.muted) { engine.toggleMute() }
                        ToggleButton(symbol: "circle.grid.3x3.fill", label: "Keypad", isOn: showKeypad) { showKeypad.toggle() }
                        ToggleButton(symbol: "speaker.wave.2.fill", label: "Speaker", isOn: call.speakerOn) { engine.toggleSpeaker() }
                    }
                    // Platform actions (S2): hold and on-demand recording go through /v1/calls/{id}; both need the
                    // platform call id, which arrives with the INVITE (inbound) or the 18x/200 (outbound).
                    HStack(spacing: 40) {
                        ToggleButton(symbol: "pause.fill", label: call.heldByMe ? "Resume" : "Hold", isOn: call.heldByMe,
                                     enabled: call.phase == .active && call.platformCallID != nil && !session.controlBusy) {
                            Task { await session.toggleHold() }
                        }
                        ToggleButton(symbol: "record.circle", label: call.recording ? "Recording" : "Record", isOn: call.recording,
                                     tint: .red, enabled: call.phase == .active && call.platformCallID != nil && !session.controlBusy) {
                            Task { await session.toggleRecording() }
                        }
                    }
                    if let error = session.controlError {
                        Text(error.userMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .onTapGesture { session.clearControlError() }
                    }
                    RoundButton(symbol: "phone.down.fill", label: "End", tint: .red) { engine.hangUp() }
                }
            }
            Spacer(minLength: 24)
        }
        .padding()
        .background(Color(.systemBackground))
        .sheet(isPresented: $showKeypad) {
            Keypad(keys: [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]) { key in
                if let c = key.first { engine.sendDTMF(c) }
            }
            .padding(.top, 32)
            .presentationDetents([.medium])
        }
        .onReceive(ticker) { now = $0 }
    }

    private var statusLine: String {
        guard let call = engine.call else { return "" }
        switch call.phase {
        case .incomingPush, .incoming: return "Incoming call"
        case .dialing: return "Calling…"
        case .ringing: return "Ringing…"
        case .active:
            let t = call.connectedAt.map { Self.duration(since: $0, now: now) } ?? "Connected"
            var marks: [String] = []
            if call.heldByMe { marks.append("on hold") }
            if call.recording { marks.append("● recording") }
            return marks.isEmpty ? t : t + " · " + marks.joined(separator: " · ")
        case .held: return "On hold"
        case .ending: return "Ending…"
        case .ended(let reason): return "Call ended · \(reason)"
        }
    }

    private static func duration(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct RoundButton: View {
    let symbol: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.title)
                    .frame(width: 72, height: 72)
                    .background(tint, in: Circle())
                    .foregroundStyle(.white)
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ToggleButton: View {
    let symbol: String
    let label: String
    let isOn: Bool
    var tint: Color = .primary
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 64, height: 64)
                    .background(isOn ? tint : Color(.secondarySystemBackground), in: Circle())
                    .foregroundStyle(isOn ? Color(.systemBackground) : Color.primary)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
