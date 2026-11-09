import AdBlockCore
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var filters: FilterManager
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var activity = DNSActivity()
    @State private var showOnlyBlocked = false
    @State private var search = ""

    private var entries: [DNSActivity.Entry] {
        activity.recent.filter { entry in
            (!showOnlyBlocked || entry.blocked) && (search.isEmpty || entry.domain.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        stat(activity.blockedQueries.formatted(), "bloccate", .red)
                        Divider()
                        stat(activity.totalQueries.formatted(), "richieste", .blue)
                        Divider()
                        stat(percentage, "filtrate", .green)
                    }
                    .frame(maxWidth: .infinity)
                    Toggle("Mostra solo bloccate", isOn: $showOnlyBlocked)
                } footer: {
                    Text("Dal \(activity.since.formatted(date: .abbreviated, time: .shortened)). Scorri una riga per sbloccare o bloccare un dominio.")
                }

                Section("Recenti") {
                    if tunnel.status != .connected && activity.recent.isEmpty {
                        Text("Attiva \"Blocca pubblicità nelle app\" per vedere qui le richieste.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        HStack {
                            Image(systemName: entry.blocked ? "xmark.octagon.fill" : "checkmark.circle")
                                .foregroundStyle(entry.blocked ? Color.red : Color.green)
                            VStack(alignment: .leading) {
                                Text(entry.domain).lineLimit(1).truncationMode(.middle)
                                Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if entry.blocked {
                                Button("Consenti") { filters.addAllowlisted(entry.domain) }
                                    .tint(.green)
                            } else {
                                Button("Blocca") { filters.addBlocked(entry.domain) }
                                    .tint(.red)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Cerca dominio")
            .navigationTitle("Attività")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Azzera") {
                        tunnel.send(.resetStatistics)
                        activity = DNSActivity()
                        activity.save()
                    }
                }
            }
            .task {
                while !Task.isCancelled {
                    activity = DNSActivity.load()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private var percentage: String {
        guard activity.totalQueries > 0 else { return "0%" }
        return (Double(activity.blockedQueries) / Double(activity.totalQueries)).formatted(.percent.precision(.fractionLength(0)))
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack {
            Text(value).font(.title3.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
