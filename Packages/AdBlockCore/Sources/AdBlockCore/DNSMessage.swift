import Foundation

/// Minimal DNS wire format helpers (RFC 1035) used by the DNS filter.
public enum DNSMessage {
    public enum RecordType: UInt16 {
        case a = 1
        case aaaa = 28
        case opt = 41
    }

    public struct Query: Equatable, Sendable {
        public var id: UInt16
        public var name: String
        public var type: UInt16
        public var qclass: UInt16
        /// Offset of the first byte after the question section.
        public var questionEnd: Int
    }

    public static let headerSize = 12

    // MARK: Parsing

    /// Parses a standard query with exactly one question.
    public static func parseQuery(_ bytes: [UInt8]) -> Query? {
        guard bytes.count >= headerSize else { return nil }
        let flags = readUInt16(bytes, 2)
        let isResponse = flags & 0x8000 != 0
        let opcode = (flags >> 11) & 0x0F
        guard !isResponse, opcode == 0, readUInt16(bytes, 4) == 1 else { return nil }

        var offset = headerSize
        guard let name = readName(bytes, offset: &offset), offset + 4 <= bytes.count else { return nil }
        let type = readUInt16(bytes, offset)
        let qclass = readUInt16(bytes, offset + 2)
        return Query(id: readUInt16(bytes, 0), name: name, type: type, qclass: qclass, questionEnd: offset + 4)
    }

    /// Reads an uncompressed name (queries never use compression).
    static func readName(_ bytes: [UInt8], offset: inout Int) -> String? {
        var labels: [String] = []
        var total = 0
        while offset < bytes.count {
            let length = Int(bytes[offset])
            offset += 1
            if length == 0 {
                return labels.isEmpty ? "." : labels.joined(separator: ".")
            }
            // Compression pointers / extended labels are not expected in a question.
            guard length & 0xC0 == 0, offset + length <= bytes.count else { return nil }
            total += length + 1
            guard total <= 255 else { return nil }
            labels.append(String(decoding: bytes[offset..<offset + length], as: UTF8.self).lowercased())
            offset += length
        }
        return nil
    }

    // MARK: Building

    /// Answer returned for blocked domains:
    /// `A 0.0.0.0` / `AAAA ::` and an empty NOERROR answer for other types,
    /// which makes apps fail fast instead of retrying.
    public static func blockedResponse(to queryBytes: [UInt8], query: Query, ttl: UInt32 = 60) -> [UInt8] {
        let requestFlags = readUInt16(queryBytes, 2)
        let recursionDesired = requestFlags & 0x0100
        // QR=1, RA=1, RCODE=0 (NOERROR)
        let flags: UInt16 = 0x8000 | recursionDesired | 0x0080

        var answer: [UInt8] = []
        switch query.type {
        case RecordType.a.rawValue:
            answer = resourceRecord(type: query.type, ttl: ttl, data: [0, 0, 0, 0])
        case RecordType.aaaa.rawValue:
            answer = resourceRecord(type: query.type, ttl: ttl, data: [UInt8](repeating: 0, count: 16))
        default:
            break
        }

        var response: [UInt8] = []
        response.reserveCapacity(query.questionEnd + answer.count)
        appendUInt16(&response, query.id)
        appendUInt16(&response, flags)
        appendUInt16(&response, 1) // QDCOUNT
        appendUInt16(&response, answer.isEmpty ? 0 : 1) // ANCOUNT
        appendUInt16(&response, 0) // NSCOUNT
        appendUInt16(&response, 0) // ARCOUNT
        response.append(contentsOf: queryBytes[headerSize..<query.questionEnd])
        response.append(contentsOf: answer)
        return response
    }

    /// SERVFAIL response, used when no upstream server answers.
    public static func serverFailure(to queryBytes: [UInt8], query: Query) -> [UInt8] {
        var response = Array(queryBytes[0..<query.questionEnd])
        let requestFlags = readUInt16(queryBytes, 2)
        let flags: UInt16 = 0x8000 | (requestFlags & 0x0100) | 0x0080 | 0x0002
        writeUInt16(&response, 2, flags)
        writeUInt16(&response, 6, 0)
        writeUInt16(&response, 8, 0)
        writeUInt16(&response, 10, 0)
        return response
    }

    private static func resourceRecord(type: UInt16, ttl: UInt32, data: [UInt8]) -> [UInt8] {
        var record: [UInt8] = [0xC0, 0x0C] // pointer to the name in the question
        appendUInt16(&record, type)
        appendUInt16(&record, 1) // IN
        appendUInt16(&record, UInt16(ttl >> 16))
        appendUInt16(&record, UInt16(ttl & 0xFFFF))
        appendUInt16(&record, UInt16(data.count))
        record.append(contentsOf: data)
        return record
    }

    // MARK: Rewriting

    /// Returns a copy of the message with a different transaction id.
    public static func replacingID(_ bytes: [UInt8], with id: UInt16) -> [UInt8] {
        guard bytes.count >= 2 else { return bytes }
        var copy = bytes
        writeUInt16(&copy, 0, id)
        return copy
    }

    public static func transactionID(_ bytes: [UInt8]) -> UInt16? {
        bytes.count >= 2 ? readUInt16(bytes, 0) : nil
    }

    /// Lowers the EDNS(0) advertised UDP payload size so that answers fit in
    /// a single tunnel packet (we don't implement DNS over TCP fallback).
    public static func clampingEDNSPayloadSize(_ bytes: [UInt8], query: Query, maxSize: UInt16) -> [UInt8] {
        guard bytes.count >= headerSize else { return bytes }
        let answerCount = Int(readUInt16(bytes, 6))
        let authorityCount = Int(readUInt16(bytes, 8))
        let additionalCount = Int(readUInt16(bytes, 10))
        guard answerCount == 0, authorityCount == 0, additionalCount > 0 else { return bytes }

        var copy = bytes
        var offset = query.questionEnd
        for _ in 0..<additionalCount {
            guard skipName(copy, offset: &offset), offset + 10 <= copy.count else { return bytes }
            let type = readUInt16(copy, offset)
            let payloadSize = readUInt16(copy, offset + 2)
            let rdLength = Int(readUInt16(copy, offset + 8))
            if type == RecordType.opt.rawValue, payloadSize > maxSize {
                writeUInt16(&copy, offset + 2, maxSize)
            }
            offset += 10 + rdLength
        }
        return copy
    }

    private static func skipName(_ bytes: [UInt8], offset: inout Int) -> Bool {
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length == 0 { offset += 1; return true }
            if length & 0xC0 == 0xC0 { offset += 2; return offset <= bytes.count }
            offset += length + 1
        }
        return false
    }

    // MARK: Byte helpers

    static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func appendUInt16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    static func writeUInt16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }
}
