import SwiftUI
import SoftphoneKit

/// The "From" picker (docs/05): loads the presentable numbers when it opens, keeps them for five minutes.
struct CallerIDSheet: View {
    @Bindable var store: CallerIDStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.isLoading && store.items.isEmpty {
                    loadingRow
                } else {
                    defaultSection
                    numbersSection
                    anonymousSection
                    errorSection
                }
            }
            .navigationTitle("Caller ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.load() }               // fetch on open only (docs/05)
            .refreshable { await store.load(force: true) }
        }
        .presentationDetents([.medium, .large])
    }

    private var numbers: [CallerIDStore.Option] { store.items.filter { $0.number != "anonymous" } }
    private var hasAnonymous: Bool { store.items.contains { $0.number == "anonymous" } }

    private var loadingRow: some View {
        HStack {
            ProgressView()
            Text("Loading your numbers…").foregroundStyle(.secondary)
        }
    }

    private var defaultSection: some View {
        Section {
            row(title: defaultTitle, subtitle: "Decided by the platform", selected: store.selected == nil) {
                store.select(nil)
            }
        }
    }

    @ViewBuilder private var numbersSection: some View {
        if !numbers.isEmpty {
            Section("Present as") {
                ForEach(numbers, id: \.number) { o in
                    let isIdentity = o.source == "identity"
                    row(title: isIdentity ? o.label : o.number,
                        subtitle: isIdentity ? o.number : o.label,
                        selected: store.selected == o.number) { store.select(o.number) }
                }
            }
        }
    }

    @ViewBuilder private var anonymousSection: some View {
        if hasAnonymous {
            Section {
                row(title: "Anonymous", subtitle: "Number withheld", selected: store.selected == "anonymous") {
                    store.select("anonymous")
                }
            }
        }
    }

    @ViewBuilder private var errorSection: some View {
        if let error = store.lastError {
            let tone: Color = error.code == "caller_id_gone" ? .secondary : .red
            Section { Text(error.userMessage).foregroundStyle(tone) }
        }
    }

    private var defaultTitle: String {
        if let d = store.platformDefault, let n = d.number { return d.anonymous == true ? "Default (anonymous)" : "Default · \(n)" }
        return "Default"
    }

    private func row(title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { action(); dismiss() }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.primary) }
            }
        }
    }
}
