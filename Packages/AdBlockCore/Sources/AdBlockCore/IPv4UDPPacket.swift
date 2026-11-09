import Foundation

/// An IPv4 + UDP datagram as read from / written to the packet tunnel.
public struct IPv4UDPPacket: Equatable, Sendable {
    public var sourceAddress: [UInt8]
    public var destinationAddress: [UInt8]
    public var sourcePort: UInt16
    public var destinationPort: UInt16
    public var payload: [UInt8]

    public init(sourceAddress: [UInt8], destinationAddress: [UInt8], sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8]) {
        self.sourceAddress = sourceAddress
        self.destinationAddress = destinationAddress
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.payload = payload
    }

    /// Parses an unfragmented IPv4 UDP packet.
    public init?(bytes: [UInt8]) {
        guard bytes.count >= 28, bytes[0] >> 4 == 4 else { return nil }
        let headerLength = Int(bytes[0] & 0x0F) * 4
        let totalLength = Int(DNSMessage.readUInt16(bytes, 2))
        let fragment = DNSMessage.readUInt16(bytes, 6)
        guard headerLength >= 20,
              totalLength <= bytes.count,
              totalLength >= headerLength + 8,
              bytes[9] == 17, // UDP
              fragment & 0x3FFF == 0 // no offset and no "more fragments"
        else { return nil }

        let udpLength = Int(DNSMessage.readUInt16(bytes, headerLength + 4))
        guard udpLength >= 8, headerLength + udpLength <= totalLength else { return nil }

        sourceAddress = Array(bytes[12..<16])
        destinationAddress = Array(bytes[16..<20])
        sourcePort = DNSMessage.readUInt16(bytes, headerLength)
        destinationPort = DNSMessage.readUInt16(bytes, headerLength + 2)
        payload = Array(bytes[(headerLength + 8)..<(headerLength + udpLength)])
    }

    /// A reply going back to the sender of this packet.
    public func reply(with payload: [UInt8]) -> IPv4UDPPacket {
        IPv4UDPPacket(
            sourceAddress: destinationAddress,
            destinationAddress: sourceAddress,
            sourcePort: destinationPort,
            destinationPort: sourcePort,
            payload: payload
        )
    }

    /// Serializes the packet, computing both IP and UDP checksums.
    public func serialized() -> [UInt8] {
        let udpLength = 8 + payload.count
        let totalLength = 20 + udpLength
        var packet = [UInt8](repeating: 0, count: totalLength)

        packet[0] = 0x45 // IPv4, 20 byte header
        DNSMessage.writeUInt16(&packet, 2, UInt16(totalLength))
        DNSMessage.writeUInt16(&packet, 6, 0x4000) // don't fragment
        packet[8] = 64 // TTL
        packet[9] = 17 // UDP
        packet.replaceSubrange(12..<16, with: sourceAddress)
        packet.replaceSubrange(16..<20, with: destinationAddress)
        DNSMessage.writeUInt16(&packet, 10, Self.checksum(packet[0..<20]))

        DNSMessage.writeUInt16(&packet, 20, sourcePort)
        DNSMessage.writeUInt16(&packet, 22, destinationPort)
        DNSMessage.writeUInt16(&packet, 24, UInt16(udpLength))
        packet.replaceSubrange(28..<totalLength, with: payload)

        var pseudo: [UInt8] = sourceAddress + destinationAddress + [0, 17]
        DNSMessage.appendUInt16(&pseudo, UInt16(udpLength))
        pseudo.append(contentsOf: packet[20..<totalLength])
        var udpChecksum = Self.checksum(pseudo[...])
        if udpChecksum == 0 { udpChecksum = 0xFFFF }
        DNSMessage.writeUInt16(&packet, 26, udpChecksum)
        return packet
    }

    /// RFC 1071 internet checksum.
    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var sum: UInt32 = 0
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.endIndex {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum)
    }
}
