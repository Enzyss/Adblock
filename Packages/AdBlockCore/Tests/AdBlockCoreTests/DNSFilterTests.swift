import XCTest
@testable import AdBlockCore

final class DNSFilterTests: XCTestCase {
    // MARK: Blocklist

    func testParsesAllListFormats() {
        var builder = DomainBlocklistBuilder()
        builder.add(listText: """
        # hosts file
        127.0.0.1 localhost
        0.0.0.0 tracker.example.com
        0.0.0.0 a.one.com a.two.com # trailing comment
        ! adblock style
        ||doubleclick.net^
        ||important.com^$important
        ||client-specific.com^$client=127.0.0.1
        @@||safe.doubleclick.net^
        plain-domain.org
        """)
        let list = builder.build()

        XCTAssertTrue(list.isBlocked("tracker.example.com"))
        XCTAssertTrue(list.isBlocked("a.one.com"))
        XCTAssertTrue(list.isBlocked("a.two.com"))
        XCTAssertTrue(list.isBlocked("doubleclick.net"))
        XCTAssertTrue(list.isBlocked("stats.g.doubleclick.net"))
        XCTAssertTrue(list.isBlocked("IMPORTANT.com."))
        XCTAssertTrue(list.isBlocked("plain-domain.org"))

        XCTAssertFalse(list.isBlocked("safe.doubleclick.net"))
        XCTAssertFalse(list.isBlocked("example.com"))
        XCTAssertFalse(list.isBlocked("localhost"))
        XCTAssertFalse(list.isBlocked("client-specific.com"))
    }

    func testUserAllowlistWinsOverSubdomainBlocks() {
        var builder = DomainBlocklistBuilder()
        builder.block(domain: "ads.shop.com")
        builder.allow(domain: "shop.com")
        XCTAssertFalse(builder.build().isBlocked("ads.shop.com"))
    }

    func testSerializationRoundTrip() throws {
        var builder = DomainBlocklistBuilder()
        builder.add(listText: "||a.com^\n||b.org^\n@@||ok.a.com^")
        let list = builder.build()
        let decoded = try XCTUnwrap(DomainBlocklist(serialized: list.serialized()))
        XCTAssertEqual(decoded, list)
        XCTAssertTrue(decoded.isBlocked("x.b.org"))
        XCTAssertFalse(decoded.isBlocked("ok.a.com"))
        XCTAssertNil(DomainBlocklist(serialized: Data("garbage".utf8)))
    }

    // MARK: Packets

    func testBlockedQueryGetsNullAnswer() throws {
        var builder = DomainBlocklistBuilder()
        builder.block(domain: "ads.example.com")
        let filter = DNSPacketFilter(blocklist: builder.build())

        let packet = makeQueryPacket(name: "ads.example.com", type: 1, id: 0xBEEF)
        guard case let .blocked(domain, responseBytes) = filter.handle(packet: packet) else {
            return XCTFail("expected blocked")
        }
        XCTAssertEqual(domain, "ads.example.com")

        let response = try XCTUnwrap(IPv4UDPPacket(bytes: responseBytes))
        XCTAssertEqual(response.sourceAddress, [198, 18, 0, 1])
        XCTAssertEqual(response.destinationAddress, [198, 18, 0, 2])
        XCTAssertEqual(response.sourcePort, 53)
        XCTAssertEqual(response.destinationPort, 50_000)

        let dns = response.payload
        XCTAssertEqual(DNSMessage.readUInt16(dns, 0), 0xBEEF)
        XCTAssertEqual(DNSMessage.readUInt16(dns, 2) & 0x8000, 0x8000, "QR bit")
        XCTAssertEqual(DNSMessage.readUInt16(dns, 2) & 0x000F, 0, "NOERROR")
        XCTAssertEqual(DNSMessage.readUInt16(dns, 6), 1, "one answer")
        XCTAssertEqual(Array(dns.suffix(4)), [0, 0, 0, 0], "0.0.0.0")

        // Checksums must verify to zero.
        XCTAssertEqual(IPv4UDPPacket.checksum(responseBytes[0..<20]), 0)
    }

    func testAllowedQueryIsForwardedWithClampedEDNS() throws {
        let filter = DNSPacketFilter(blocklist: .empty)
        let packet = makeQueryPacket(name: "apple.com", type: 28, id: 7, ednsSize: 4_096)
        guard case let .forward(domain, query, original) = filter.handle(packet: packet) else {
            return XCTFail("expected forward")
        }
        XCTAssertEqual(domain, "apple.com")
        XCTAssertEqual(original.destinationPort, 53)
        // OPT record: name(1) type(2) class=payload size(2)...
        let parsed = try XCTUnwrap(DNSMessage.parseQuery(query))
        XCTAssertEqual(DNSMessage.readUInt16(query, parsed.questionEnd + 3), DNSPacketFilter.maxUDPPayload)

        let reply = DNSPacketFilter.responsePacket(for: original, reply: [1, 2, 3])
        XCTAssertEqual(IPv4UDPPacket(bytes: reply)?.payload, [1, 2, 3])
    }

    func testNonDNSPacketsAreIgnored() {
        let filter = DNSPacketFilter(blocklist: .empty)
        XCTAssertEqual(filter.handle(packet: [0x60, 0, 0, 0]), .ignore)
        let packet = IPv4UDPPacket(sourceAddress: [1, 1, 1, 1], destinationAddress: [2, 2, 2, 2], sourcePort: 1, destinationPort: 123, payload: [0]).serialized()
        XCTAssertEqual(filter.handle(packet: packet), .ignore)
    }

    func testServerFailure() throws {
        let packet = try XCTUnwrap(IPv4UDPPacket(bytes: makeQueryPacket(name: "x.com", type: 1, id: 3)))
        let failure = try XCTUnwrap(DNSPacketFilter.failurePacket(for: packet))
        let dns = try XCTUnwrap(IPv4UDPPacket(bytes: failure)).payload
        XCTAssertEqual(DNSMessage.readUInt16(dns, 2) & 0x000F, 2)
    }

    // MARK: Helpers

    private func makeQueryPacket(name: String, type: UInt16, id: UInt16, ednsSize: UInt16? = nil) -> [UInt8] {
        var dns: [UInt8] = []
        DNSMessage.appendUInt16(&dns, id)
        DNSMessage.appendUInt16(&dns, 0x0100) // RD
        DNSMessage.appendUInt16(&dns, 1)
        DNSMessage.appendUInt16(&dns, 0)
        DNSMessage.appendUInt16(&dns, 0)
        DNSMessage.appendUInt16(&dns, ednsSize == nil ? 0 : 1)
        for label in name.split(separator: ".") {
            dns.append(UInt8(label.utf8.count))
            dns.append(contentsOf: label.utf8)
        }
        dns.append(0)
        DNSMessage.appendUInt16(&dns, type)
        DNSMessage.appendUInt16(&dns, 1)
        if let ednsSize {
            dns.append(0) // root name
            DNSMessage.appendUInt16(&dns, 41)
            DNSMessage.appendUInt16(&dns, ednsSize)
            dns.append(contentsOf: [0, 0, 0, 0]) // extended rcode + flags
            DNSMessage.appendUInt16(&dns, 0) // rdlength
        }
        return IPv4UDPPacket(
            sourceAddress: [198, 18, 0, 2],
            destinationAddress: [198, 18, 0, 1],
            sourcePort: 50_000,
            destinationPort: 53,
            payload: dns
        ).serialized()
    }
}
