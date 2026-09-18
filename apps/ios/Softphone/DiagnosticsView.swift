import SwiftUI
import SoftphoneKit

/// What support needs when "it doesn't register": the SDK version, instance, reachability as the SDK and iOS see
/// it, and the recent redacted log lines, shareable as text. No secrets reach this screen (Redactor, S6).
struct DiagnosticsView: View {
    @Environment(CallEngine.self) private var engine
    @Environment(AppSession.self) private var session
    @State private var lines: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section("State") {
                    row("Registration", engine.registration.label)
                    row("SDK reachable", engine.sdkReachable ? "yes" : "no")
                    row("iOS path", engine.pathSatisfied ? "satisfied" : "unsatisfied")
                    row("liblinphone", engine.sdkVersion)
                    row("Instance", engine.instanceID)
                    if let a = engine.account { row("Edge", a.serverURI) }
                    if let e = session.enrollment { row("Enrolled as", "\(e.userExtension)@\(e.tenantSlug) · \(e.apiBase.host() ?? "")") }
                }
                Section("Recent log (\(lines.count))") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.contains(" E [") ? .red : (line.contains(" W [") || line.contains(" N [") ? .orange : .primary))
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh") { lines = LogBuffer.shared.snapshot() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareText, subject: Text("CallTo diagnostics")) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .task { lines = LogBuffer.shared.snapshot() }
        }
    }

    private var shareText: String {
        var head = [
            "CallTo diagnostics \(Date().formatted(.iso8601))",
            "registration: \(engine.registration.label)",
            "sdk reachable: \(engine.sdkReachable), ios path: \(engine.pathSatisfied ? "satisfied" : "unsatisfied")",
            "liblinphone \(engine.sdkVersion), instance \(engine.instanceID)",
        ]
        if let a = engine.account { head.append("edge: \(a.serverURI)") }
        return (head + [""] + lines).joined(separator: "\n")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).font(.footnote.monospaced())
        }
    }
}
