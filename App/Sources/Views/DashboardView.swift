import AdBlockCore
import SwiftUI
import UIKit

struct DashboardView: View {
    @EnvironmentObject private var filters: FilterManager
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var showSafariGuide = false
    @State private var activity = DNSActivity()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusHeader(level: protectionLevel)
                        .listRowBackground(Color.clear)
                }

                safariSection
                appsSection
                updateSection
            }
            .navigationTitle("AdBlock")
            .refreshable { await filters.update() }
            .sheet(isPresented: $showSafariGuide) { SafariSetupGuide() }
            .task {
                while !Task.isCancelled {
                    activity = DNSActivity.load()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private var protectionLevel: StatusHeader.Level {
        let safari = filters.anySafariBlockerEnabled
        let apps = tunnel.status == .connected
        switch (safari, apps) {
        case (true, true): return filters.allSafariBlockersEnabled ? .full : .partial
        case (true, false), (false, true): return .partial
        case (false, false): return .off
        }
    }

    // MARK: Sections

    private var safariSection: some View {
        Section {
            ForEach(FilterCategory.safariCategories) { category in
                HStack {
                    Image(systemName: filters.safariEnabled[category] == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(filters.safariEnabled[category] == true ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                        if let status = filters.status[category] {
                            Text(status.error ?? "\(status.ruleCount.formatted()) regole\(status.truncated ? " (limite raggiunto)" : "")")
                                .font(.caption)
                                .foregroundStyle(status.error == nil ? Color.secondary : Color.red)
                        }
                    }
                    Spacer()
                    Text(filters.safariEnabled[category] == true ? "Attivo" : "Da attivare")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !filters.allSafariBlockersEnabled {
                Button {
                    showSafariGuide = true
                } label: {
                    Label("Come attivare in Safari", systemImage: "questionmark.circle")
                }
            }
        } header: {
            Text("Safari")
        } footer: {
            Text("Blocca pubblicità, tracker e banner dei cookie nelle pagine web di Safari e delle app che usano Safari.")
        }
    }

    private var appsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { tunnel.isActive },
                set: { newValue in Task { await tunnel.setEnabled(newValue) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Blocca pubblicità nelle app")
                    Text(tunnel.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(tunnel.isBusy)

            LabeledContent("Domini bloccati in lista", value: filters.dnsDomainCount.formatted())
            if activity.totalQueries > 0 {
                LabeledContent("Richieste bloccate", value: "\(activity.blockedQueries.formatted()) su \(activity.totalQueries.formatted())")
            }
            if let error = tunnel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("App")
        } footer: {
            Text("Filtra le richieste DNS di tutto l'iPhone tramite una VPN locale: i dati non lasciano il dispositivo e il traffico normale non passa dal tunnel. Funziona con la maggior parte delle pubblicità in-app; non può bloccare quelle servite dagli stessi server dei contenuti (es. YouTube).")
        }
    }

    private var updateSection: some View {
        Section("Filtri") {
            if filters.isUpdating {
                HStack {
                    ProgressView()
                    Text(filters.progressMessage ?? "Aggiornamento…")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
            } else {
                Button {
                    Task { await filters.update() }
                } label: {
                    Label("Aggiorna filtri ora", systemImage: "arrow.clockwise")
                }
            }
            LabeledContent("Ultimo aggiornamento") {
                if let date = filters.lastUpdate {
                    Text(date, style: .relative)
                } else {
                    Text("Mai")
                }
            }
            LabeledContent("Regole Safari", value: filters.totalSafariRules.formatted())
            if let error = filters.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct StatusHeader: View {
    enum Level { case full, partial, off }
    let level: Level

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(color.gradient)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var icon: String {
        switch level {
        case .full: return "checkmark.shield.fill"
        case .partial: return "shield.lefthalf.filled"
        case .off: return "xmark.shield"
        }
    }

    private var color: Color {
        switch level {
        case .full: return .green
        case .partial: return .orange
        case .off: return .red
        }
    }

    private var title: String {
        switch level {
        case .full: return "Sei protetto"
        case .partial: return "Protezione parziale"
        case .off: return "Protezione disattivata"
        }
    }

    private var subtitle: String {
        switch level {
        case .full: return "Pubblicità e tracker vengono bloccati in Safari e nelle app."
        case .partial: return "Attiva tutte le estensioni di Safari e il blocco nelle app per la massima protezione."
        case .off: return "Attiva le estensioni in Safari e il blocco nelle app qui sotto."
        }
    }
}

struct SafariSetupGuide: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, "Apri l'app **Impostazioni**.")
                    step(2, "Vai su **App** → **Safari** → **Estensioni**.\n(Su iOS 17 o precedenti: **Safari** → **Estensioni**)")
                    step(3, "Attiva **AdBlock Pubblicità**, **AdBlock Privacy** e **AdBlock Fastidi**.")
                    step(4, "Torna qui: lo stato diventerà verde.")
                }
                Section {
                    Button("Apri Impostazioni") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            .navigationTitle("Attiva in Safari")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
        }
        .padding(.vertical, 4)
    }
}
