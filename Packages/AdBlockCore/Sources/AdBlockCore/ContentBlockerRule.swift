import Foundation

/// A single Safari content blocking rule (WebKit content rule list format).
/// See https://developer.apple.com/documentation/safariservices/creating-a-content-blocker
public struct ContentBlockerRule: Codable, Equatable, Sendable {
    public struct Trigger: Codable, Equatable, Sendable {
        public var urlFilter: String
        public var urlFilterIsCaseSensitive: Bool?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?
        public var resourceType: [String]?
        public var loadType: [String]?
        public var loadContext: [String]?

        public init(
            urlFilter: String,
            urlFilterIsCaseSensitive: Bool? = nil,
            ifDomain: [String]? = nil,
            unlessDomain: [String]? = nil,
            resourceType: [String]? = nil,
            loadType: [String]? = nil,
            loadContext: [String]? = nil
        ) {
            self.urlFilter = urlFilter
            self.urlFilterIsCaseSensitive = urlFilterIsCaseSensitive
            self.ifDomain = ifDomain
            self.unlessDomain = unlessDomain
            self.resourceType = resourceType
            self.loadType = loadType
            self.loadContext = loadContext
        }

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case loadContext = "load-context"
        }
    }

    public struct Action: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case block
            case cssDisplayNone = "css-display-none"
            case ignorePreviousRules = "ignore-previous-rules"
            case blockCookies = "block-cookies"
        }

        public var type: Kind
        public var selector: String?

        public init(type: Kind, selector: String? = nil) {
            self.type = type
            self.selector = selector
        }
    }

    public var trigger: Trigger
    public var action: Action

    public init(trigger: Trigger, action: Action) {
        self.trigger = trigger
        self.action = action
    }

    /// Rule that disables every previous rule on the given site (allowlist).
    public static func allowlist(domain: String) -> ContentBlockerRule {
        ContentBlockerRule(
            trigger: Trigger(urlFilter: ".*", ifDomain: ["*" + domain]),
            action: Action(type: .ignorePreviousRules)
        )
    }
}

extension Array where Element == ContentBlockerRule {
    /// JSON payload expected by a content blocker extension.
    public func contentBlockerJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
