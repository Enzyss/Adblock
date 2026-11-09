import Foundation

/// Files and settings shared between the app and its extensions through the
/// App Group container.
///
/// The App Group identifier is injected in every target's Info.plist under
/// the `AppGroupID` key (see `project.yml`), so it only lives in one place.
///
/// Sideloading tools (iLoader, SideStore, AltStore...) re-sign the app with
/// their own App Group (e.g. `group.com.enzyss.adblock.ABCDE12345`). To keep
/// the app and its extensions talking to each other, the group actually
/// granted in `embedded.mobileprovision` wins over the Info.plist value.
public enum SharedContainer {
    public static let groupIdentifier: String = {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String) ?? "group.com.enzyss.adblock"
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let groups = appGroups(fromProvisioningProfile: data),
              !groups.isEmpty
        else { return configured }
        return groups.first { $0 == configured }
            ?? groups.first { $0.hasPrefix(configured) }
            ?? groups[0]
    }()

    /// Extracts the App Groups from a (CMS signed) provisioning profile.
    public static func appGroups(fromProvisioningProfile data: Data) -> [String]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements["com.apple.security.application-groups"] as? [String]
    }

    public static var url: URL {
        #if canImport(Darwin)
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            return url
        }
        #endif
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("AdBlockShared", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: groupIdentifier) ?? .standard
    }

    /// JSON rules loaded by the Safari content blocker of a category.
    public static func blockerListURL(for category: FilterCategory) -> URL {
        url.appendingPathComponent("blockerList-\(category.rawValue).json")
    }

    /// Compiled DNS blocklist loaded by the packet tunnel.
    public static var dnsBlocklistURL: URL {
        url.appendingPathComponent("dnsBlocklist.bin")
    }

    /// Recent DNS activity written by the packet tunnel.
    public static var activityURL: URL {
        url.appendingPathComponent("activity.json")
    }

    public enum Keys {
        public static let upstreamDNS = "upstreamDNS"
    }
}

/// Upstream DNS resolvers the tunnel forwards allowed queries to.
public enum UpstreamDNS: String, CaseIterable, Identifiable, Codable, Sendable {
    case cloudflare
    case quad9
    case google
    case adguard

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cloudflare: return "Cloudflare (1.1.1.1)"
        case .quad9: return "Quad9 (9.9.9.9) – blocca malware"
        case .google: return "Google (8.8.8.8)"
        case .adguard: return "AdGuard DNS (94.140.14.14) – blocco extra"
        }
    }

    public var servers: [String] {
        switch self {
        case .cloudflare: return ["1.1.1.1", "1.0.0.1"]
        case .quad9: return ["9.9.9.9", "149.112.112.112"]
        case .google: return ["8.8.8.8", "8.8.4.4"]
        case .adguard: return ["94.140.14.14", "94.140.15.15"]
        }
    }

    public static var current: UpstreamDNS {
        SharedContainer.defaults.string(forKey: SharedContainer.Keys.upstreamDNS).flatMap(UpstreamDNS.init(rawValue:)) ?? .cloudflare
    }
}

/// Statistics and recent requests recorded by the DNS filter.
public struct DNSActivity: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var domain: String
        public var date: Date
        public var blocked: Bool

        public init(id: UUID = UUID(), domain: String, date: Date, blocked: Bool) {
            self.id = id
            self.domain = domain
            self.date = date
            self.blocked = blocked
        }
    }

    public static let maxEntries = 300

    public var totalQueries: Int = 0
    public var blockedQueries: Int = 0
    public var since: Date = Date()
    public var recent: [Entry] = []

    public init() {}

    public mutating func record(domain: String, blocked: Bool, at date: Date = Date()) {
        totalQueries += 1
        if blocked { blockedQueries += 1 }
        recent.insert(Entry(domain: domain, date: date, blocked: blocked), at: 0)
        if recent.count > Self.maxEntries {
            recent.removeLast(recent.count - Self.maxEntries)
        }
    }

    public static func load(from url: URL = SharedContainer.activityURL) -> DNSActivity {
        guard let data = try? Data(contentsOf: url),
              let activity = try? JSONDecoder().decode(DNSActivity.self, from: data)
        else { return DNSActivity() }
        return activity
    }

    public func save(to url: URL = SharedContainer.activityURL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Messages the app sends to the running packet tunnel.
public enum TunnelMessage: String {
    case reloadBlocklist = "reload"
    case resetStatistics = "reset-stats"
}
