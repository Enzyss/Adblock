import Foundation

/// Converts Adblock Plus / AdGuard style filter lists (EasyList & co.) into
/// Safari content blocker rules.
///
/// Supported syntax (the subset that Safari can actually enforce):
/// - network rules: `||domain^`, `|https://`, `*` wildcards, `^` separators,
///   `@@` exceptions, `$third-party`, `$domain=`, resource types, `$match-case`
/// - page allowlisting: `@@||domain^$document`
/// - element hiding: `##selector`, `domain##selector`, `~domain##selector`,
///   `domain#@#selector`
///
/// Everything Safari can't express (scriptlets, extended CSS, `$redirect`,
/// `$csp`, `$removeparam`, regex rules...) is skipped and counted.
public struct SafariRuleConverter: Sendable {
    /// Maximum number of rules a single Safari content blocker accepts.
    public static let safariRuleLimit = 150_000

    public struct Result: Sendable {
        public var rules: [ContentBlockerRule]
        /// Number of filter lines that produced at least one rule.
        public var convertedFilters: Int
        /// Number of filter lines that are not supported by Safari.
        public var skippedFilters: Int
        /// True when the rule limit forced us to drop rules.
        public var truncated: Bool
    }

    public var maxRules: Int
    /// How many generic CSS selectors are merged into a single rule.
    public var selectorsPerRule: Int

    public init(maxRules: Int = SafariRuleConverter.safariRuleLimit, selectorsPerRule: Int = 40) {
        self.maxRules = maxRules
        self.selectorsPerRule = max(1, selectorsPerRule)
    }

    // MARK: - Public API

    public func convert(
        filterLists: [String],
        allowlistedDomains: [String] = []
    ) -> Result {
        var state = ConversionState()

        for list in filterLists {
            for line in list.split(whereSeparator: \.isNewline) {
                state.process(line: String(line))
            }
        }

        let allowlist = allowlistedDomains
            .compactMap(DomainName.normalize)
            .uniqued()
            .map(ContentBlockerRule.allowlist(domain:))

        // Exceptions and the user allowlist must always survive truncation,
        // and must come *after* the rules they cancel.
        let reserved = state.exceptionRules.count + allowlist.count
        var budget = max(0, maxRules - reserved)

        let blockRules = Array(state.blockRules.prefix(budget))
        budget -= blockRules.count

        let cssRules = state.buildCosmeticRules(selectorsPerRule: selectorsPerRule)
        let keptCSS = Array(cssRules.prefix(budget))

        let truncated = blockRules.count < state.blockRules.count || keptCSS.count < cssRules.count
        let exceptions = Array(state.exceptionRules.prefix(maxRules - allowlist.count))
        let rules = keptCSS + blockRules + exceptions + Array(allowlist.prefix(maxRules))

        return Result(
            rules: Array(rules.prefix(maxRules)),
            convertedFilters: state.converted,
            skippedFilters: state.skipped,
            truncated: truncated || rules.count > maxRules
        )
    }

    /// Converts a single network filter. Exposed for tests.
    public static func networkRule(from filter: String) -> ContentBlockerRule? {
        NetworkFilterParser.parse(filter)
    }
}

// MARK: - Conversion state

private struct ConversionState {
    var blockRules: [ContentBlockerRule] = []
    var exceptionRules: [ContentBlockerRule] = []
    var converted = 0
    var skipped = 0

    /// Generic selector -> domains on which it must NOT apply.
    var genericSelectors: [String: Set<String>] = [:]
    var genericOrder: [String] = []

    /// Domain specific hiding rules.
    var specificRules: [(domains: Set<String>, selector: String)] = []
    /// Selector -> domains where hiding is disabled (`domain#@#selector`).
    var cosmeticExceptions: [String: Set<String>] = [:]

    mutating func process(line rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return }

        if Self.isUnsupportedCosmetic(line) {
            skipped += 1
            return
        }
        if let range = line.range(of: "#@#") {
            addCosmeticException(domains: String(line[..<range.lowerBound]), selector: String(line[range.upperBound...]))
            return
        }
        if let range = line.range(of: "##") {
            addCosmetic(domains: String(line[..<range.lowerBound]), selector: String(line[range.upperBound...]))
            return
        }
        if line.hasPrefix("#") {
            // Hosts-file style comment
            return
        }

        guard let rule = NetworkFilterParser.parse(line) else {
            skipped += 1
            return
        }
        converted += 1
        if rule.action.type == .ignorePreviousRules {
            exceptionRules.append(rule)
        } else {
            blockRules.append(rule)
        }
    }

    // MARK: Cosmetic

    static let unsupportedCosmeticMarkers = [
        "#?#", "#@?#", "#$#", "#@$#", "#%#", "#@%#", "$$", "$@$", "##^", "##+js", "#@#+js",
    ]

    static let unsupportedPseudoClasses = [
        ":-abp-", ":has-text(", ":contains(", ":xpath(", ":matches-css", ":upward(",
        ":remove(", ":style(", ":matches-path(", ":min-text-length(", ":watch-attr(",
        ":matches-attr(", ":matches-prop(", ":others(", ":if(", ":if-not(",
        ":nth-ancestor(", ":properties(", ":remove-attr(", ":remove-class(",
    ]

    static func isUnsupportedCosmetic(_ line: String) -> Bool {
        unsupportedCosmeticMarkers.contains { line.contains($0) }
    }

    static func isSupportedSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count < 2_000 else { return false }
        let lowered = selector.lowercased()
        if unsupportedPseudoClasses.contains(where: { lowered.contains($0) }) { return false }
        // Safari's JSON parser chokes on raw control characters.
        if selector.unicodeScalars.contains(where: { $0.value < 0x20 }) { return false }
        return true
    }

    mutating func addCosmetic(domains domainPart: String, selector rawSelector: String) {
        let selector = rawSelector.trimmingCharacters(in: .whitespaces)
        guard Self.isSupportedSelector(selector) else {
            skipped += 1
            return
        }
        let parsed = DomainList.parse(domainPart, separator: ",")
        guard parsed.isValid else {
            skipped += 1
            return
        }
        converted += 1

        if parsed.included.isEmpty {
            if genericSelectors[selector] == nil {
                genericSelectors[selector] = []
                genericOrder.append(selector)
            }
            genericSelectors[selector]?.formUnion(parsed.excluded)
        } else {
            // Safari can't mix if-domain and unless-domain: keep the positive part.
            specificRules.append((domains: parsed.included, selector: selector))
        }
    }

    mutating func addCosmeticException(domains domainPart: String, selector rawSelector: String) {
        let selector = rawSelector.trimmingCharacters(in: .whitespaces)
        let parsed = DomainList.parse(domainPart, separator: ",")
        guard parsed.isValid, !parsed.included.isEmpty, !selector.isEmpty else {
            skipped += 1
            return
        }
        converted += 1
        cosmeticExceptions[selector, default: []].formUnion(parsed.included)
    }

    func buildCosmeticRules(selectorsPerRule: Int) -> [ContentBlockerRule] {
        var rules: [ContentBlockerRule] = []

        // Generic selectors grouped by their exclusion list.
        var groups: [String: (excluded: [String], selectors: [String])] = [:]
        var groupOrder: [String] = []
        for selector in genericOrder {
            var excluded = genericSelectors[selector] ?? []
            excluded.formUnion(cosmeticExceptions[selector] ?? [])
            let sortedExcluded = excluded.sorted()
            let key = sortedExcluded.joined(separator: ",")
            if groups[key] == nil {
                groups[key] = (sortedExcluded, [])
                groupOrder.append(key)
            }
            groups[key]?.selectors.append(selector)
        }
        for key in groupOrder {
            guard let group = groups[key] else { continue }
            for chunk in group.selectors.chunked(into: selectorsPerRule) {
                rules.append(ContentBlockerRule(
                    trigger: .init(
                        urlFilter: ".*",
                        unlessDomain: group.excluded.isEmpty ? nil : group.excluded.map { "*" + $0 }
                    ),
                    action: .init(type: .cssDisplayNone, selector: chunk.joined(separator: ", "))
                ))
            }
        }

        // Domain specific selectors grouped by domain set.
        var specificGroups: [String: (domains: [String], selectors: [String])] = [:]
        var specificOrder: [String] = []
        for entry in specificRules {
            let domains = entry.domains.subtracting(cosmeticExceptions[entry.selector] ?? []).sorted()
            guard !domains.isEmpty else { continue }
            let key = domains.joined(separator: ",")
            if specificGroups[key] == nil {
                specificGroups[key] = (domains, [])
                specificOrder.append(key)
            }
            specificGroups[key]?.selectors.append(entry.selector)
        }
        for key in specificOrder {
            guard let group = specificGroups[key] else { continue }
            for chunk in group.selectors.uniqued().chunked(into: selectorsPerRule) {
                rules.append(ContentBlockerRule(
                    trigger: .init(urlFilter: ".*", ifDomain: group.domains.map { "*" + $0 }),
                    action: .init(type: .cssDisplayNone, selector: chunk.joined(separator: ", "))
                ))
            }
        }
        return rules
    }
}

// MARK: - Network filters

enum NetworkFilterParser {
    static func parse(_ line: String) -> ContentBlockerRule? {
        var filter = Substring(line)
        var isException = false
        if filter.hasPrefix("@@") {
            isException = true
            filter = filter.dropFirst(2)
        }

        // Split pattern and options. Regex rules (/.../) are not supported.
        var pattern = filter
        var optionsText: Substring?
        if let dollar = filter.lastIndex(of: "$") {
            let candidate = filter[filter.index(after: dollar)...]
            if Self.looksLikeOptions(candidate) {
                pattern = filter[..<dollar]
                optionsText = candidate
            }
        }
        if pattern.count > 1, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            return nil
        }

        var options = FilterOptions()
        if let optionsText {
            guard let parsed = FilterOptions.parse(optionsText, isException: isException) else { return nil }
            options = parsed
        }

        // `@@||example.com^$document` -> allowlist the whole site.
        if isException, options.isDocumentException {
            guard let domain = Self.plainDomain(fromPattern: pattern) else { return nil }
            return ContentBlockerRule.allowlist(domain: domain)
        }
        if options.isDocumentException || options.isElementHidingException {
            // Exceptions that only affect cosmetic rules can't be expressed precisely.
            return nil
        }

        guard let urlFilter = URLFilterBuilder.regex(fromPattern: String(pattern)) else { return nil }

        // Refuse rules that would block every request everywhere.
        if urlFilter == ".*", !isException,
           options.ifDomains == nil, options.resourceTypes == nil, options.loadType == nil {
            return nil
        }

        var trigger = ContentBlockerRule.Trigger(urlFilter: urlFilter)
        trigger.urlFilterIsCaseSensitive = options.matchCase ? true : nil
        trigger.resourceType = options.resourceTypes
        trigger.loadType = options.loadType
        trigger.loadContext = options.loadContext
        if let ifDomains = options.ifDomains {
            trigger.ifDomain = ifDomains
        } else if let unless = options.unlessDomains {
            trigger.unlessDomain = unless
        }

        return ContentBlockerRule(
            trigger: trigger,
            action: .init(type: isException ? .ignorePreviousRules : .block)
        )
    }

    private static let optionCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~,=|.*")

    static func looksLikeOptions(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { optionCharacters.contains($0) }
    }

    /// Extracts `example.com` from `||example.com^` / `||example.com`.
    static func plainDomain(fromPattern pattern: Substring) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var domain = pattern.dropFirst(2)
        if domain.hasSuffix("^") { domain = domain.dropLast() }
        if domain.hasSuffix("/") { domain = domain.dropLast() }
        return DomainName.normalize(String(domain))
    }
}

private struct FilterOptions {
    var resourceTypes: [String]?
    var loadType: [String]?
    var loadContext: [String]?
    var ifDomains: [String]?
    var unlessDomains: [String]?
    var matchCase = false
    var isDocumentException = false
    var isElementHidingException = false

    /// Resource types that Safari understands, mapped from ABP option names.
    static let resourceTypeMap: [String: [String]] = [
        "script": ["script"],
        "image": ["image"],
        "stylesheet": ["style-sheet"],
        "css": ["style-sheet"],
        "font": ["font"],
        "media": ["media"],
        "xmlhttprequest": ["raw"],
        "xhr": ["raw"],
        "websocket": ["raw"],
        "ping": ["raw"],
        "other": ["raw"],
        "object": ["raw"],
        "subdocument": ["document"],
        "frame": ["document"],
        "popup": ["popup"],
    ]

    static let allResourceTypes = ["document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup"]

    static func parse(_ text: Substring, isException: Bool) -> FilterOptions? {
        var options = FilterOptions()
        var includedTypes: [String] = []
        var excludedTypes: Set<String> = []
        var hasSubdocument = false

        for rawOption in text.split(separator: ",") {
            var option = rawOption.lowercased()
            let negated = option.hasPrefix("~")
            if negated { option.removeFirst() }

            var value: String?
            if let eq = option.firstIndex(of: "=") {
                value = String(option[option.index(after: eq)...])
                option = String(option[..<eq])
            }

            switch option {
            case "third-party", "3p":
                options.loadType = negated ? ["first-party"] : ["third-party"]
            case "first-party", "1p":
                options.loadType = negated ? ["third-party"] : ["first-party"]
            case "match-case":
                options.matchCase = !negated
            case "important", "all":
                continue
            case "domain", "from":
                guard let value else { return nil }
                let domains = DomainList.parse(value, separator: "|")
                guard domains.isValid else { return nil }
                if !domains.included.isEmpty {
                    options.ifDomains = domains.included.sorted().map { "*" + $0 }
                } else if !domains.excluded.isEmpty {
                    options.unlessDomains = domains.excluded.sorted().map { "*" + $0 }
                }
            case "document", "doc":
                if isException {
                    options.isDocumentException = true
                } else if negated {
                    excludedTypes.insert("document")
                } else {
                    includedTypes.append("document")
                }
            case "elemhide", "ehide", "generichide", "ghide", "specifichide", "shide", "genericblock":
                guard isException else { return nil }
                options.isElementHidingException = true
            default:
                guard let mapped = resourceTypeMap[option] else {
                    // $redirect, $csp, $removeparam, $badfilter, ... are not supported.
                    return nil
                }
                if option == "subdocument" || option == "frame" { hasSubdocument = !negated }
                if negated {
                    excludedTypes.formUnion(mapped)
                } else {
                    includedTypes.append(contentsOf: mapped)
                }
            }
        }

        if !includedTypes.isEmpty {
            options.resourceTypes = includedTypes.uniqued()
        } else if !excludedTypes.isEmpty {
            let remaining = allResourceTypes.filter { !excludedTypes.contains($0) }
            guard !remaining.isEmpty else { return nil }
            options.resourceTypes = remaining
        }
        if hasSubdocument, options.resourceTypes == ["document"] {
            options.loadContext = ["child-frame"]
        }
        return options
    }
}

// MARK: - URL pattern -> regex

enum URLFilterBuilder {
    /// Characters that have a meaning in Safari's regex dialect.
    private static let specialCharacters: Set<Character> = [".", "?", "+", "(", ")", "[", "]", "{", "}", "\\", "$", "|"]

    /// Matches the scheme and any subdomain, used for `||` anchors.
    static let domainAnchor = "^[^:]+://+([^/:]+\\.)?"
    /// Matches the separator after a host name.
    static let hostSeparator = "[/:]"
    /// Matches any ABP separator character.
    static let separator = "[/:?&=]"

    static func regex(fromPattern rawPattern: String) -> String? {
        var pattern = Substring(rawPattern)
        var prefix = ""
        var suffix = ""
        var inHost = false

        if pattern.hasPrefix("||") {
            prefix = domainAnchor
            pattern = pattern.dropFirst(2)
            inHost = true
        } else if pattern.hasPrefix("|") {
            prefix = "^"
            pattern = pattern.dropFirst()
        }
        if pattern.hasSuffix("|") {
            suffix = "$"
            pattern = pattern.dropLast()
        }

        // Unanchored patterns: leading/trailing wildcards are implicit.
        if prefix.isEmpty { while pattern.hasPrefix("*") { pattern = pattern.dropFirst() } }
        if suffix.isEmpty { while pattern.hasSuffix("*") { pattern = pattern.dropLast() } }

        // URLs never contain spaces: such "patterns" are malformed options (e.g. `$csp=...`).
        guard pattern.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 }) else { return nil }
        guard !pattern.contains("|") else { return nil }

        if pattern.isEmpty {
            return prefix.isEmpty && suffix.isEmpty ? ".*" : nil
        }
        // Very short unanchored patterns would match far too much.
        if prefix.isEmpty, pattern.count < 3 { return nil }

        var body = ""
        let characters = Array(pattern)
        for (index, character) in characters.enumerated() {
            let isLast = index == characters.count - 1
            switch character {
            case "*":
                body += ".*"
                inHost = false
            case "^":
                if inHost {
                    body += hostSeparator
                    inHost = false
                } else if isLast {
                    // Trailing separator may also be the end of the URL: drop it.
                    continue
                } else {
                    body += separator
                }
            case "/", ":", "?", "#", "&", "=":
                inHost = false
                body += specialCharacters.contains(character) ? "\\\(character)" : String(character)
            default:
                body += specialCharacters.contains(character) ? "\\\(character)" : String(character)
            }
        }
        if prefix == domainAnchor, body.hasPrefix(".*") {
            // `||*foo` is equivalent to an unanchored pattern.
            prefix = ""
        }
        return prefix + body + suffix
    }
}

// MARK: - Domain helpers

struct DomainList {
    var included: Set<String> = []
    var excluded: Set<String> = []
    var isValid = true

    static func parse(_ text: String, separator: Character) -> DomainList {
        var list = DomainList()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return list }
        var sawEntry = false
        for raw in trimmed.split(separator: separator) {
            var entry = String(raw).trimmingCharacters(in: .whitespaces)
            let negated = entry.hasPrefix("~")
            if negated { entry.removeFirst() }
            sawEntry = true
            // Wildcard TLDs (`google.*`) and regex domains are not supported.
            guard let domain = DomainName.normalize(entry) else { continue }
            if negated { list.excluded.insert(domain) } else { list.included.insert(domain) }
        }
        if sawEntry, list.included.isEmpty, list.excluded.isEmpty { list.isValid = false }
        return list
    }
}

public enum DomainName {
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")

    /// Lowercases and validates a host name. Returns nil for anything that
    /// isn't a plain ASCII domain (wildcards, IPs with ports, IDNs...).
    public static func normalize(_ raw: String) -> String? {
        var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.hasPrefix("*.") { domain.removeFirst(2) }
        while domain.hasSuffix(".") { domain.removeLast() }
        while domain.hasPrefix(".") { domain.removeFirst() }
        guard !domain.isEmpty, domain.count <= 253 else { return nil }
        guard domain.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard !domain.contains("..") else { return nil }
        return domain
    }
}

// MARK: - Collection helpers

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
