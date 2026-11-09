import Foundation

/// Compact, memory friendly domain blocklist used by the DNS filter.
///
/// Network extensions on iOS have a tight memory budget (~50 MB), so instead
/// of keeping hundreds of thousands of `String`s around we store a sorted
/// array of 64-bit FNV-1a hashes (8 bytes per domain) and binary search it.
/// A lookup checks the domain and every parent domain, so blocking
/// `doubleclick.net` also blocks `ad.doubleclick.net`.
public struct DomainBlocklist: Sendable, Equatable {
    public private(set) var blockedHashes: [UInt64]
    public private(set) var allowedDomains: Set<String>

    public static let empty = DomainBlocklist(blockedHashes: [], allowedDomains: [])

    public init(blockedHashes: [UInt64], allowedDomains: Set<String>) {
        self.blockedHashes = blockedHashes
        self.allowedDomains = allowedDomains
    }

    public var count: Int { blockedHashes.count }

    public func isBlocked(_ rawDomain: String) -> Bool {
        guard let domain = DomainName.normalize(rawDomain) else { return false }
        let candidates = Self.suffixes(of: domain)
        // An allowlisted parent domain wins over any blocked subdomain.
        if !allowedDomains.isEmpty, candidates.contains(where: { allowedDomains.contains(String($0)) }) {
            return false
        }
        return candidates.contains { containsHash(Self.hash($0)) }
    }

    /// `a.b.c` -> [`a.b.c`, `b.c`, `c`]
    static func suffixes(of domain: String) -> [Substring] {
        var result: [Substring] = []
        var candidate = Substring(domain)
        while true {
            result.append(candidate)
            guard let dot = candidate.firstIndex(of: ".") else { return result }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }

    private func containsHash(_ value: UInt64) -> Bool {
        var low = 0
        var high = blockedHashes.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let current = blockedHashes[mid]
            if current == value { return true }
            if current < value { low = mid + 1 } else { high = mid - 1 }
        }
        return false
    }

    /// 64-bit FNV-1a.
    public static func hash<S: StringProtocol>(_ text: S) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: - Serialization

    private static let magic: [UInt8] = Array("ADBL1".utf8)

    /// Binary format: magic, UInt32 hash count, hashes (little endian),
    /// then the newline separated allowlist.
    public func serialized() -> Data {
        var data = Data(Self.magic)
        var count = UInt32(blockedHashes.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.reserveCapacity(data.count + blockedHashes.count * 8)
        for hash in blockedHashes {
            var value = hash.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array(allowedDomains.sorted().joined(separator: "\n").utf8))
        return data
    }

    public init?(serialized data: Data) {
        let bytes = [UInt8](data)
        let headerSize = Self.magic.count + 4
        guard bytes.count >= headerSize, Array(bytes[0..<Self.magic.count]) == Self.magic else { return nil }
        var offset = Self.magic.count
        let count = Int(Self.readUInt32(bytes, at: offset))
        offset += 4
        guard bytes.count >= offset + count * 8 else { return nil }

        var hashes = [UInt64]()
        hashes.reserveCapacity(count)
        for _ in 0..<count {
            var value: UInt64 = 0
            for shift in 0..<8 {
                value |= UInt64(bytes[offset + shift]) << (8 * UInt64(shift))
            }
            hashes.append(value)
            offset += 8
        }
        let allowText = String(decoding: bytes[offset...], as: UTF8.self)
        let allowed = Set(allowText.split(separator: "\n").map(String.init))
        self.init(blockedHashes: hashes, allowedDomains: allowed)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

/// Builds a `DomainBlocklist` from hosts files, plain domain lists and
/// Adblock-style DNS lists (`||domain^`, `@@||domain^`).
public struct DomainBlocklistBuilder {
    private var blocked = Set<UInt64>()
    private var allowed = Set<String>()
    public private(set) var parsedRules = 0

    public init() {}

    private static let ignoredHosts: Set<String> = [
        "localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost",
        "ip6-loopback", "ip6-localnet", "ip6-mcastprefix", "ip6-allnodes", "ip6-allrouters",
        "ip6-allhosts", "0.0.0.0",
    ]

    private static let hostsAddresses: Set<String> = ["0.0.0.0", "127.0.0.1", "::", "::1", "::0"]

    public mutating func add(listText: String) {
        for line in listText.split(whereSeparator: \.isNewline) {
            add(line: String(line))
        }
    }

    public mutating func block(domain: String) {
        guard let domain = DomainName.normalize(domain) else { return }
        blocked.insert(DomainBlocklist.hash(domain))
    }

    public mutating func allow(domain: String) {
        guard let domain = DomainName.normalize(domain) else { return }
        allowed.insert(domain)
    }

    public mutating func add(line rawLine: String) {
        var line = Substring(rawLine)
        if let hashIndex = line.firstIndex(of: "#") { line = line[..<hashIndex] }
        line = Substring(line.trimmingCharacters(in: .whitespaces))
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return }

        // Adblock syntax
        if line.hasPrefix("||") || line.hasPrefix("@@||") {
            let isException = line.hasPrefix("@@")
            var body = line.dropFirst(isException ? 4 : 2)
            if let dollar = body.firstIndex(of: "$") {
                let options = body[body.index(after: dollar)...].split(separator: ",")
                // Options like $client, $dnstype, $denyallow change semantics: skip.
                guard options.allSatisfy({ $0 == "important" || $0 == "all" }) else { return }
                body = body[..<dollar]
            }
            guard body.hasSuffix("^") || body.hasSuffix("^|") else { return }
            body = body.prefix { $0 != "^" }
            guard !body.contains("*"), !body.contains("/"), let domain = DomainName.normalize(String(body)) else { return }
            if Self.ignoredHosts.contains(domain) { return }
            parsedRules += 1
            if isException { allowed.insert(domain) } else { blocked.insert(DomainBlocklist.hash(domain)) }
            return
        }

        // Hosts file: "0.0.0.0 domain [domain...]"
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        var domains: ArraySlice<Substring>
        if parts.count >= 2, Self.hostsAddresses.contains(String(parts[0])) {
            domains = parts.dropFirst()
        } else if parts.count == 1 {
            domains = parts[...]
        } else {
            return
        }
        for candidate in domains {
            guard !candidate.contains("*"), let domain = DomainName.normalize(String(candidate)),
                  domain.contains("."), !Self.ignoredHosts.contains(domain) else { continue }
            parsedRules += 1
            blocked.insert(DomainBlocklist.hash(domain))
        }
    }

    public func build() -> DomainBlocklist {
        DomainBlocklist(blockedHashes: blocked.sorted(), allowedDomains: allowed)
    }
}
