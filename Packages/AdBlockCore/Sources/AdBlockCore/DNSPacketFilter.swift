import Foundation

/// Decides what to do with a packet coming out of the tunnel.
public struct DNSPacketFilter: Sendable {
    public enum Decision: Equatable, Sendable {
        /// The domain is blocked: write `packet` back to the tunnel.
        case blocked(domain: String, packet: [UInt8])
        /// Forward `query` (DNS payload) upstream, then answer `original`.
        case forward(domain: String, query: [UInt8], original: IPv4UDPPacket)
        /// Not a DNS query we understand.
        case ignore
    }

    /// Max EDNS payload size advertised upstream; keeps replies under the tunnel MTU.
    public static let maxUDPPayload: UInt16 = 1_400

    public var blocklist: DomainBlocklist

    public init(blocklist: DomainBlocklist) {
        self.blocklist = blocklist
    }

    public func handle(packet bytes: [UInt8]) -> Decision {
        guard let packet = IPv4UDPPacket(bytes: bytes),
              packet.destinationPort == 53,
              let query = DNSMessage.parseQuery(packet.payload)
        else { return .ignore }

        if blocklist.isBlocked(query.name) {
            let response = DNSMessage.blockedResponse(to: packet.payload, query: query)
            return .blocked(domain: query.name, packet: packet.reply(with: response).serialized())
        }

        let upstreamQuery = DNSMessage.clampingEDNSPayloadSize(packet.payload, query: query, maxSize: Self.maxUDPPayload)
        return .forward(domain: query.name, query: upstreamQuery, original: packet)
    }

    /// Builds the tunnel packet carrying an upstream reply back to the client.
    public static func responsePacket(for original: IPv4UDPPacket, reply: [UInt8]) -> [UInt8] {
        original.reply(with: reply).serialized()
    }

    /// SERVFAIL packet for queries whose upstream lookup failed.
    public static func failurePacket(for original: IPv4UDPPacket) -> [UInt8]? {
        guard let query = DNSMessage.parseQuery(original.payload) else { return nil }
        return original.reply(with: DNSMessage.serverFailure(to: original.payload, query: query)).serialized()
    }
}
