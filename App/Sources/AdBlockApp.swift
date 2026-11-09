import AdBlockCore
import BackgroundTasks
import SwiftUI

@main
struct AdBlockApp: App {
    @StateObject private var filters = FilterManager()
    @StateObject private var tunnel = TunnelManager()
    @Environment(\.scenePhase) private var scenePhase

    static var refreshTaskIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.enzyss.adblock") + ".refresh"
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(filters)
                .environmentObject(tunnel)
                .task {
                    filters.onDNSBlocklistChanged = { [weak tunnel = tunnel] in
                        tunnel?.send(.reloadBlocklist)
                    }
                    await filters.refreshSafariState()
                    if filters.needsAutomaticUpdate {
                        await filters.update()
                    }
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                Task { await filters.refreshSafariState() }
            case .background:
                Self.scheduleBackgroundRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskIdentifier)) {
            Self.scheduleBackgroundRefresh()
            await filters.update()
        }
    }

    /// Keeps the filter lists fresh (iOS decides the exact timing).
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
