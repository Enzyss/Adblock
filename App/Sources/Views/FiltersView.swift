import AdBlockCore
import SwiftUI

struct FiltersView: View {
    @EnvironmentObject private var filters: FilterManager
    @EnvironmentObject private var tunnel: TunnelManager
    @AppStorage(SharedContainer.Keys.upstreamDNS, store: SharedContainer.defaults)
    private var upstream: UpstreamDNS = .cloudflare

    var body: some View {
        NavigationStack {
            List {
                ForEach(FilterCategory.allCases) { category in
                    Section {
                        ForEach(FilterCatalog.lists(in: category)) { list in
                            Toggle(isOn: Binding(
                                get: { filters.isEnabled(list) },
                                set: { filters.setList(list, enabled: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.name)
                                    Text(list.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(category.title)
                    } footer: {
                        if let status = filters.status[category], category != .dns {
                            Text("\(status.ruleCount.formatted()) regole attive · \(status.skippedFilters.formatted()) filtri non supportati da Safari ignorati")
                        } else if category == .dns {
                            Text("\(filters.dnsDomainCount.formatted()) domini bloccati in tutte le app")
                        }
                    }
                }

                Section {
                    Picker("Server DNS", selection: $upstream) {
                        ForEach(UpstreamDNS.allCases) { server in
                            Text(server.title).tag(server)
                        }
                    }
                    .onChange(of: upstream) { _ in
                        tunnel.send(.reloadBlocklist)
                    }
                } header: {
                    Text("DNS")
                } footer: {
                    Text("Il server a cui vengono inoltrate le richieste non bloccate quando il blocco nelle app è attivo.")
                }
            }
            .navigationTitle("Filtri")
            .overlay(alignment: .bottom) {
                if filters.isUpdating {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(filters.progressMessage ?? "Aggiornamento…")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                }
            }
        }
    }
}
