import SwiftUI
import UIKit
import SoftphoneKit

/// First screen until the device is enrolled (ADR-0004): the code from the admin UI's Devices tab, typed or
/// arriving as a `callto://enroll?code=…&api=…` link. No SIP password is ever asked here.
struct EnrollView: View {
    @Environment(AppSession.self) private var session
    @State private var code = ""
    @State private var apiBase = EnrollView.defaultAPIBase
    @State private var showAdvanced = false
    @State private var showDeveloper = false
    @State private var showScanner = false
    @State private var scanNote: String?

    static let defaultAPIBase = "https://91-99-163-145.sslip.io"

    var body: some View {
        NavigationStack {
            Form {
                if QRScannerView.available {
                    Section {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan the QR code", systemImage: "qrcode.viewfinder")
                        }
                    } footer: {
                        Text("Your administrator shows it under the user's Devices tab.")
                    }
                }
                Section {
                    TextField("Enrollment code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .font(.system(.title2, design: .monospaced))
                        .onChange(of: code) { _, v in code = Self.format(v) }
                } header: {
                    Text(QRScannerView.available ? "Or type the code" : "Enroll this device")
                } footer: {
                    Text("Ask your administrator for a code (user › Devices › Enroll a device) or open the link they sent you. Codes work once and expire after ten minutes.")
                }
                if let scanNote {
                    Section { Text(scanNote).foregroundStyle(.secondary) }
                }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        TextField("Platform URL", text: $apiBase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
                Section {
                    Button {
                        Task { await enroll() }
                    } label: {
                        HStack {
                            Text("Enroll")
                            if session.isEnrolling { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!isValid || session.isEnrolling)
                }
                if let error = session.enrollError {
                    Section { Text(error.userMessage).foregroundStyle(.red) }
                }
                #if DEBUG
                Section {
                    Button("Developer: enter a SIP account manually") { showDeveloper = true }
                        .foregroundStyle(.secondary)
                }
                #endif
            }
            .navigationTitle("CallTo")
            .sheet(isPresented: $showDeveloper) { AccountSetupView() }
            .fullScreenCover(isPresented: $showScanner) {
                NavigationStack {
                    QRScannerView { payload in
                        showScanner = false
                        handleScanned(payload)
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan the QR code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } } }
                }
            }
            .onOpenURL { url in
                guard let link = EnrollLink(url: url) else { return }
                code = Self.format(link.code)
                apiBase = link.apiBase.absoluteString
                Task { await enroll() }
            }
        }
    }

    /// A scanned payload is the admin UI's `callto://enroll?…` link, or just a code typed into some other QR.
    private func handleScanned(_ payload: String) {
        if let url = URL(string: payload), let link = EnrollLink(url: url) {
            code = Self.format(link.code)
            apiBase = link.apiBase.absoluteString
            scanNote = nil
            Task { await enroll() }
        } else if Self.format(payload).replacingOccurrences(of: "-", with: "").count == 8 {
            code = Self.format(payload)
            scanNote = nil
            Task { await enroll() }
        } else {
            scanNote = "That QR code is not a CallTo enrollment code."
        }
    }

    private var isValid: Bool {
        code.replacingOccurrences(of: "-", with: "").count == 8 && URL(string: apiBase)?.host() != nil
    }

    private func enroll() async {
        guard let base = URL(string: apiBase.trimmingCharacters(in: .whitespaces)) else { return }
        await session.enroll(
            code: code.replacingOccurrences(of: "-", with: ""),
            apiBase: base,
            deviceName: UIDevice.current.name,
            appID: Bundle.main.bundleIdentifier ?? "com.callto365.softphone"
        )
    }

    /// "2wdh3g9g" -> "2WDH-3G9G" while typing.
    static func format(_ raw: String) -> String {
        let clean = raw.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
        if clean.count > 4 { return String(clean.prefix(4)) + "-" + String(clean.dropFirst(4)) }
        return String(clean)
    }
}
