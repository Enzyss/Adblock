import AdBlockCore
import Foundation
import NetworkExtension

/// Installs, starts and stops the DNS filtering tunnel that blocks ads in apps.
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    private var tunnelBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.enzyss.adblock") + ".PacketTunnel"
    }

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        Task { await load() }
    }

    var isActive: Bool {
        switch status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    var statusText: String {
        switch status {
        case .connected: return "Attivo"
        case .connecting: return "Connessione…"
        case .reasserting: return "Riconnessione…"
        case .disconnecting: return "Disattivazione…"
        case .disconnected: return "Disattivato"
        case .invalid: return "Non configurato"
        @unknown default: return "Sconosciuto"
        }
    }

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelBundleIdentifier }
                ?? managers.first
            refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool) async {
        isBusy = true
        defer { isBusy = false }
        if enabled { await start() } else { await stop() }
    }

    private func start() async {
        do {
            let manager = self.manager ?? NETunnelProviderManager()
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = tunnelBundleIdentifier
            configuration.serverAddress = "Filtro DNS locale"
            configuration.disconnectOnSleep = false
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "AdBlock – blocco nelle app"

            // Keep the filter always on, reconnecting automatically.
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            manager.onDemandRules = [rule]
            manager.isOnDemandEnabled = true
            manager.isEnabled = true

            // The first save shows the system "Add VPN configuration" prompt.
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel()
            self.manager = manager
            refreshStatus()
        } catch {
            errorMessage = "Impossibile attivare il blocco nelle app: \(error.localizedDescription)"
        }
    }

    private func stop() async {
        guard let manager else { return }
        manager.isOnDemandEnabled = false
        do {
            try await manager.saveToPreferences()
        } catch {
            errorMessage = error.localizedDescription
        }
        manager.connection.stopVPNTunnel()
        refreshStatus()
    }

    /// Asks the running tunnel to reload the blocklist / settings.
    func send(_ message: TunnelMessage) {
        guard status == .connected, let session = manager?.connection as? NETunnelProviderSession else { return }
        try? session.sendProviderMessage(Data(message.rawValue.utf8)) { _ in }
    }

    private func refreshStatus() {
        status = manager?.connection.status ?? .invalid
    }
}
