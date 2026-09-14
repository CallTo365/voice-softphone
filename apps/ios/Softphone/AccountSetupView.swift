import SwiftUI
import SoftphoneKit

/// Phase 0 only: type the SIP account by hand. Replaced by enrollment (ADR-0004) in phase 3;
/// stays available in DEBUG builds as a developer screen.
struct AccountSetupView: View {
    @Environment(CallEngine.self) private var engine

    @State private var username = "1001"
    @State private var domain = "acme.sip.local"
    @State private var serverHost = "91-99-163-145.sslip.io"
    @State private var serverPort = "5061"
    @State private var transport: SIPAccount.Transport = .tls
    @State private var password = ""
    @State private var trustAnyCertificate = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Extension", text: $username)
                        .keyboardType(.numberPad)
                    TextField("SIP domain", text: $domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                Section("Edge") {
                    TextField("Server host", text: $serverHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $serverPort)
                        .keyboardType(.numberPad)
                    Picker("Transport", selection: $transport) {
                        ForEach(SIPAccount.Transport.allCases, id: \.self) { t in
                            Text(t.rawValue.uppercased()).tag(t)
                        }
                    }
                    #if DEBUG
                    Toggle("Trust any certificate (development)", isOn: $trustAnyCertificate)
                    #endif
                }
                Section {
                    Button("Register") { register() }
                        .disabled(username.isEmpty || domain.isEmpty || serverHost.isEmpty || password.isEmpty)
                } footer: {
                    Text("Development screen. Production builds enroll with a code from the admin UI and never ask for a SIP password.")
                }
                if let error = engine.lastError {
                    Section { Text(error.userMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("CallTo")
        }
    }

    private func register() {
        let account = SIPAccount(
            username: username.trimmingCharacters(in: .whitespaces),
            domain: domain.trimmingCharacters(in: .whitespaces),
            serverHost: serverHost.trimmingCharacters(in: .whitespaces),
            serverPort: Int(serverPort) ?? 5061,
            transport: transport,
            password: password,
            trustAnyCertificate: trustAnyCertificate
        )
        engine.configure(account: account)
    }
}
