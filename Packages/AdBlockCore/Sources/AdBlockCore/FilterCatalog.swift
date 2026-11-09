import Foundation

/// The kind of blocking a filter list feeds.
///
/// Safari content blockers are limited to 150,000 rules each, so the Safari
/// lists are split across three extensions (ads, privacy, annoyances).
/// DNS lists feed the system-wide packet tunnel that filters ads inside apps.
public enum FilterCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case ads
    case privacy
    case annoyances
    case dns

    public var id: String { rawValue }

    /// Categories handled by a Safari content blocker extension.
    public static let safariCategories: [FilterCategory] = [.ads, .privacy, .annoyances]

    public var title: String {
        switch self {
        case .ads: return "Pubblicità"
        case .privacy: return "Tracker e privacy"
        case .annoyances: return "Fastidi (cookie, popup)"
        case .dns: return "Blocco DNS (app)"
        }
    }

    /// Suffix appended to the main app bundle identifier to obtain the
    /// identifier of the matching content blocker extension.
    public var contentBlockerSuffix: String? {
        switch self {
        case .ads: return "ContentBlocker.Ads"
        case .privacy: return "ContentBlocker.Privacy"
        case .annoyances: return "ContentBlocker.Annoyances"
        case .dns: return nil
        }
    }
}

/// A downloadable filter list.
public struct FilterListSource: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var url: URL
    public var category: FilterCategory
    public var enabledByDefault: Bool

    public init(id: String, name: String, summary: String, url: URL, category: FilterCategory, enabledByDefault: Bool) {
        self.id = id
        self.name = name
        self.summary = summary
        self.url = url
        self.category = category
        self.enabledByDefault = enabledByDefault
    }
}

public enum FilterCatalog {
    // swiftlint:disable force_unwrapping
    public static let all: [FilterListSource] = [
        // MARK: Safari - ads
        FilterListSource(
            id: "easylist",
            name: "EasyList",
            summary: "La lista principale contro la pubblicità.",
            url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
            category: .ads,
            enabledByDefault: true
        ),
        FilterListSource(
            id: "easylist-italy",
            name: "EasyList Italy",
            summary: "Pubblicità dei siti italiani.",
            url: URL(string: "https://easylist-downloads.adblockplus.org/easylistitaly.txt")!,
            category: .ads,
            enabledByDefault: true
        ),
        FilterListSource(
            id: "adguard-mobile",
            name: "AdGuard Mobile Ads",
            summary: "Pubblicità specifiche per siti mobile.",
            url: URL(string: "https://filters.adtidy.org/extension/safari/filters/11.txt")!,
            category: .ads,
            enabledByDefault: false
        ),

        // MARK: Safari - privacy
        FilterListSource(
            id: "easyprivacy",
            name: "EasyPrivacy",
            summary: "Blocca tracker, analytics e pixel di tracciamento.",
            url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
            category: .privacy,
            enabledByDefault: true
        ),

        // MARK: Safari - annoyances
        FilterListSource(
            id: "cookie-monster",
            name: "EasyList Cookie List",
            summary: "Nasconde i banner dei cookie.",
            url: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!,
            category: .annoyances,
            enabledByDefault: true
        ),
        FilterListSource(
            id: "fanboy-annoyance",
            name: "Fanboy's Annoyance",
            summary: "Popup, newsletter, widget social e altri fastidi.",
            url: URL(string: "https://secure.fanboy.co.nz/fanboy-annoyance.txt")!,
            category: .annoyances,
            enabledByDefault: false
        ),

        // MARK: DNS (system wide, works inside apps)
        FilterListSource(
            id: "adguard-dns",
            name: "AdGuard DNS filter",
            summary: "Domini di pubblicità e tracker, ottimizzato per il blocco DNS.",
            url: URL(string: "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt")!,
            category: .dns,
            enabledByDefault: true
        ),
        FilterListSource(
            id: "peter-lowe",
            name: "Peter Lowe's list",
            summary: "Server pubblicitari e di tracciamento (lista compatta).",
            url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext")!,
            category: .dns,
            enabledByDefault: true
        ),
        FilterListSource(
            id: "stevenblack",
            name: "StevenBlack hosts",
            summary: "Lista hosts molto ampia (adware + malware).",
            url: URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")!,
            category: .dns,
            enabledByDefault: false
        ),
    ]
    // swiftlint:enable force_unwrapping

    public static func lists(in category: FilterCategory) -> [FilterListSource] {
        all.filter { $0.category == category }
    }
}
