import SwiftUI

struct RulesView: View {
    @EnvironmentObject private var filters: FilterManager
    @State private var newAllowed = ""
    @State private var newBlocked = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("esempio.it", text: $newAllowed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit(addAllowed)
                        Button("Aggiungi", action: addAllowed)
                            .disabled(FilterManager.domain(from: newAllowed) == nil)
                    }
                    ForEach(filters.allowlist, id: \.self) { domain in
                        Label(domain, systemImage: "checkmark.seal")
                    }
                    .onDelete { offsets in
                        for domain in offsets.map({ filters.allowlist[$0] }) { filters.removeAllowlisted(domain) }
                    }
                } header: {
                    Text("Siti e domini consentiti")
                } footer: {
                    Text("Su questi siti Safari non blocca nulla e i loro domini non vengono bloccati nelle app. Utile se un sito o un'app smette di funzionare.")
                }

                Section {
                    HStack {
                        TextField("pubblicita.esempio.com", text: $newBlocked)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit(addBlocked)
                        Button("Blocca", action: addBlocked)
                            .disabled(FilterManager.domain(from: newBlocked) == nil)
                    }
                    ForEach(filters.blockedDomains, id: \.self) { domain in
                        Label(domain, systemImage: "nosign")
                    }
                    .onDelete { offsets in
                        for domain in offsets.map({ filters.blockedDomains[$0] }) { filters.removeBlocked(domain) }
                    }
                } header: {
                    Text("Domini bloccati da te")
                } footer: {
                    Text("Bloccati sia in Safari sia nelle app.")
                }

                Section {
                    NavigationLink("Regole personalizzate") {
                        CustomRulesEditor(initialText: filters.customRules)
                    }
                } footer: {
                    Text("Per utenti esperti: regole in sintassi Adblock Plus, es. `||ads.sito.it^` oppure `sito.it##.banner`.")
                }
            }
            .navigationTitle("Eccezioni")
        }
    }

    private func addAllowed() {
        if filters.addAllowlisted(newAllowed) { newAllowed = "" }
    }

    private func addBlocked() {
        if filters.addBlocked(newBlocked) { newBlocked = "" }
    }
}

private struct CustomRulesEditor: View {
    @EnvironmentObject private var filters: FilterManager
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(initialText: String) {
        _text = State(initialValue: initialText)
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.footnote, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 8)
            .navigationTitle("Regole personalizzate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        filters.saveCustomRules(text)
                        dismiss()
                    }
                }
            }
    }
}
