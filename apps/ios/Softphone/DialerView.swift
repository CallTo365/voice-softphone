import SwiftUI
import SoftphoneKit

struct DialerView: View {
    @Environment(AppSession.self) private var session
    @Environment(CallEngine.self) private var engine
    @State private var number = ""
    @State private var showCallerIDs = false
    @State private var showDiagnostics = false

    private let keys: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                RegistrationBadge(status: engine.registration)

                Text(number.isEmpty ? " " : number)
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal)

                if let store = session.callerIDs {
                    // Opens the sheet; nothing is fetched until then (docs/05).
                    Button { showCallerIDs = true } label: {
                        HStack(spacing: 4) {
                            Text("From:").foregroundStyle(.secondary)
                            Text(store.summary)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Caller ID: \(store.summary)")
                    .sheet(isPresented: $showCallerIDs) { CallerIDSheet(store: store) }
                }

                Keypad(keys: keys) { key in number.append(key) }

                HStack(spacing: 40) {
                    Button {
                        if !number.isEmpty { number.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title2)
                    }
                    .opacity(number.isEmpty ? 0 : 1)

                    Button {
                        session.placeCall(to: number)
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.title)
                            .frame(width: 72, height: 72)
                            .background(Color.green, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .disabled(number.isEmpty || !engine.registration.isRegistered)

                    Color.clear.frame(width: 28, height: 28)
                }

                if let error = engine.lastError {
                    Text(error.userMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .onTapGesture { engine.clearError() }
                }
                Spacer(minLength: 0)
            }
            .padding(.top)
            .navigationTitle(engine.account?.username ?? "CallTo")
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let e = session.enrollment {
                            Text("\(e.userDisplayName) · \(e.tenantName)")
                        }
                        Text("liblinphone \(engine.sdkVersion)")
                        Text("instance \(engine.instanceID.prefix(8))…")
                        Button("Diagnostics") { showDiagnostics = true }
                        Button("Sign out", role: .destructive) { session.signOut() }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }
}

struct RegistrationBadge: View {
    let status: RegistrationStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(status.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal)
    }

    private var color: Color {
        switch status {
        case .registered: .green
        case .registering: .yellow
        case .failed: .red
        case .cleared, .unconfigured: .gray
        }
    }
}

struct Keypad: View {
    let keys: [[String]]
    let onKey: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { key in
                        Button { onKey(key) } label: {
                            Text(key)
                                .font(.system(size: 30, weight: .regular, design: .rounded))
                                .frame(width: 72, height: 72)
                                .background(Color(.secondarySystemBackground), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
