import AdBlockCore
import Foundation
import SafariServices

/// Downloads the filter lists, converts them for Safari and for the DNS
/// filter, and keeps the user's preferences (lists, allowlist, custom rules).
@MainActor
final class FilterManager: ObservableObject {
    struct CategoryStatus: Codable, Equatable {
        var ruleCount = 0
        var skippedFilters = 0
        var truncated = false
        var error: String?
    }

    // MARK: Published state

    @Published private(set) var enabledLists: Set<String>
    @Published private(set) var allowlist: [String]
    @Published private(set) var blockedDomains: [String]
    @Published private(set) var customRules: String
    @Published private(set) var status: [FilterCategory: CategoryStatus]
    @Published private(set) var safariEnabled: [FilterCategory: Bool] = [:]
    @Published private(set) var dnsDomainCount: Int
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var isUpdating = false
    @Published private(set) var progressMessage: String?
    @Published var lastError: String?

    /// Called after a new DNS blocklist has been written (the tunnel reloads it).
    var onDNSBlocklistChanged: (@MainActor () -> Void)?

    private let defaults = SharedContainer.defaults
    private var pendingUpdate = false

    private enum Keys {
        static let enabledLists = "enabledLists"
        static let allowlist = "allowlist"
        static let blockedDomains = "blockedDomains"
        static let customRules = "customRules"
        static let status = "categoryStatus"
        static let dnsDomainCount = "dnsDomainCount"
        static let lastUpdate = "lastUpdate"
    }

    init() {
        if let saved = defaults.stringArray(forKey: Keys.enabledLists) {
            enabledLists = Set(saved)
        } else {
            enabledLists = Set(FilterCatalog.all.filter(\.enabledByDefault).map(\.id))
        }
        allowlist = defaults.stringArray(forKey: Keys.allowlist) ?? []
        blockedDomains = defaults.stringArray(forKey: Keys.blockedDomains) ?? []
        customRules = defaults.string(forKey: Keys.customRules) ?? ""
        dnsDomainCount = defaults.integer(forKey: Keys.dnsDomainCount)
        lastUpdate = defaults.object(forKey: Keys.lastUpdate) as? Date
        if let data = defaults.data(forKey: Keys.status),
           let decoded = try? JSONDecoder().decode([FilterCategory: CategoryStatus].self, from: data) {
            status = decoded
        } else {
            status = [:]
        }
    }

    // MARK: Derived values

    var needsAutomaticUpdate: Bool {
        guard let lastUpdate else { return true }
        return Date().timeIntervalSince(lastUpdate) > 3 * 24 * 3600
    }

    var totalSafariRules: Int {
        FilterCategory.safariCategories.reduce(0) { $0 + (status[$1]?.ruleCount ?? 0) }
    }

    var allSafariBlockersEnabled: Bool {
        FilterCategory.safariCategories.allSatisfy { safariEnabled[$0] == true }
    }

    var anySafariBlockerEnabled: Bool {
        FilterCategory.safariCategories.contains { safariEnabled[$0] == true }
    }

    func isEnabled(_ list: FilterListSource) -> Bool {
        enabledLists.contains(list.id)
    }

    static func contentBlockerIdentifier(for category: FilterCategory) -> String? {
        guard let suffix = category.contentBlockerSuffix, let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return "\(bundleID).\(suffix)"
    }

    // MARK: User actions

    func setList(_ list: FilterListSource, enabled: Bool) {
        if enabled { enabledLists.insert(list.id) } else { enabledLists.remove(list.id) }
        defaults.set(Array(enabledLists), forKey: Keys.enabledLists)
        rebuild()
    }

    @discardableResult
    func addAllowlisted(_ input: String) -> Bool {
        guard let domain = Self.domain(from: input), !allowlist.contains(domain) else { return false }
        allowlist.append(domain)
        allowlist.sort()
        defaults.set(allowlist, forKey: Keys.allowlist)
        blockedDomains.removeAll { $0 == domain }
        defaults.set(blockedDomains, forKey: Keys.blockedDomains)
        rebuild()
        return true
    }

    func removeAllowlisted(_ domain: String) {
        allowlist.removeAll { $0 == domain }
        defaults.set(allowlist, forKey: Keys.allowlist)
        rebuild()
    }

    @discardableResult
    func addBlocked(_ input: String) -> Bool {
        guard let domain = Self.domain(from: input), !blockedDomains.contains(domain) else { return false }
        blockedDomains.append(domain)
        blockedDomains.sort()
        defaults.set(blockedDomains, forKey: Keys.blockedDomains)
        allowlist.removeAll { $0 == domain }
        defaults.set(allowlist, forKey: Keys.allowlist)
        rebuild()
        return true
    }

    func removeBlocked(_ domain: String) {
        blockedDomains.removeAll { $0 == domain }
        defaults.set(blockedDomains, forKey: Keys.blockedDomains)
        rebuild()
    }

    func saveCustomRules(_ rules: String) {
        customRules = rules
        defaults.set(rules, forKey: Keys.customRules)
        rebuild()
    }

    /// Accepts "example.com", "https://www.example.com/page" or "*.example.com".
    static func domain(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        var host = trimmed
        if trimmed.contains("://"), let url = URL(string: trimmed), let urlHost = url.host {
            host = urlHost
        } else if let slash = trimmed.firstIndex(of: "/") {
            host = String(trimmed[..<slash])
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard let domain = DomainName.normalize(host), domain.contains(".") else { return nil }
        return domain
    }

    // MARK: Safari state

    func refreshSafariState() async {
        for category in FilterCategory.safariCategories {
            guard let identifier = Self.contentBlockerIdentifier(for: category) else { continue }
            let state = try? await SFContentBlockerManager.stateOfContentBlocker(withIdentifier: identifier)
            safariEnabled[category] = state?.isEnabled ?? false
        }
    }

    // MARK: Updating

    /// Recompiles from the cached lists (downloading only what's missing).
    private func rebuild() {
        Task { await update(downloadFreshLists: false) }
    }

    /// Downloads (if requested), converts and installs every filter.
    func update(downloadFreshLists: Bool = true) async {
        if isUpdating {
            pendingUpdate = true
            return
        }
        isUpdating = true
        lastError = nil
        defer {
            isUpdating = false
            progressMessage = nil
        }

        let sources = FilterCatalog.all.filter { enabledLists.contains($0.id) }
        progressMessage = downloadFreshLists ? "Download delle liste…" : "Preparazione…"
        let texts = await FilterDownloader.texts(for: sources, refresh: downloadFreshLists)
        let failedDownloads = sources.filter { texts[$0.id] == nil }.map(\.name)

        let allowlist = self.allowlist
        let blockedDomains = self.blockedDomains
        let customRules = self.customRules
        await refreshSafariState()

        // Safari content blockers
        for category in FilterCategory.safariCategories {
            progressMessage = "Compilazione: \(category.title)…"
            var lists = sources.filter { $0.category == category }.compactMap { texts[$0.id] }
            if category == .ads {
                lists.append(customRules)
                lists.append(blockedDomains.map { "||\($0)^" }.joined(separator: "\n"))
            }
            let input = lists
            let result = await Task.detached(priority: .userInitiated) {
                SafariRuleConverter().convert(filterLists: input, allowlistedDomains: allowlist)
            }.value

            var categoryStatus = CategoryStatus(
                ruleCount: result.rules.count,
                skippedFilters: result.skippedFilters,
                truncated: result.truncated
            )
            do {
                let data = try result.rules.contentBlockerJSON()
                try data.write(to: SharedContainer.blockerListURL(for: category), options: .atomic)
                // Disabled blockers are compiled by Safari when the user turns them on.
                if safariEnabled[category] == true, let identifier = Self.contentBlockerIdentifier(for: category) {
                    try await SFContentBlockerManager.reloadContentBlocker(withIdentifier: identifier)
                }
            } catch {
                categoryStatus.error = error.localizedDescription
            }
            status[category] = categoryStatus
        }

        // DNS filter (apps)
        progressMessage = "Compilazione: blocco DNS…"
        let dnsLists = sources.filter { $0.category == .dns }.compactMap { texts[$0.id] }
        let blocklist = await Task.detached(priority: .userInitiated) { () -> DomainBlocklist in
            var builder = DomainBlocklistBuilder()
            for list in dnsLists { builder.add(listText: list) }
            for domain in blockedDomains { builder.block(domain: domain) }
            for domain in allowlist { builder.allow(domain: domain) }
            return builder.build()
        }.value
        do {
            try blocklist.serialized().write(to: SharedContainer.dnsBlocklistURL, options: .atomic)
            dnsDomainCount = blocklist.count
            onDNSBlocklistChanged?()
        } catch {
            lastError = "Impossibile salvare il blocco DNS: \(error.localizedDescription)"
        }

        if !failedDownloads.isEmpty {
            lastError = "Download non riuscito: \(failedDownloads.joined(separator: ", ")). Controlla la connessione."
        }
        if downloadFreshLists, failedDownloads.count < sources.count {
            lastUpdate = Date()
        }
        persistStatus()

        if pendingUpdate {
            pendingUpdate = false
            Task { await update(downloadFreshLists: false) }
        }
    }

    private func persistStatus() {
        if let data = try? JSONEncoder().encode(status) {
            defaults.set(data, forKey: Keys.status)
        }
        defaults.set(dnsDomainCount, forKey: Keys.dnsDomainCount)
        defaults.set(lastUpdate, forKey: Keys.lastUpdate)
    }
}

/// Downloads filter lists, caching them on disk so that the rules can be
/// rebuilt offline (e.g. after changing the allowlist).
enum FilterDownloader {
    private static var cacheDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FilterLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cacheURL(for source: FilterListSource) -> URL {
        cacheDirectory.appendingPathComponent("\(source.id).txt")
    }

    static func texts(for sources: [FilterListSource], refresh: Bool) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for source in sources {
                group.addTask { (source.id, await text(for: source, refresh: refresh)) }
            }
            var result: [String: String] = [:]
            for await (id, text) in group {
                if let text { result[id] = text }
            }
            return result
        }
    }

    private static func text(for source: FilterListSource, refresh: Bool) async -> String? {
        let cache = cacheURL(for: source)
        let cached = try? String(contentsOf: cache, encoding: .utf8)
        if !refresh, let cached { return cached }

        var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("AdBlock-iOS/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return cached }
            let text = String(decoding: data, as: UTF8.self)
            try? data.write(to: cache, options: .atomic)
            return text
        } catch {
            return cached
        }
    }
}
