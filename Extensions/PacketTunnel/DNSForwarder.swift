import AdBlockCore
import Foundation
import Network
import os

/// Forwards allowed DNS queries to an upstream resolver over UDP and hands
/// the answers back as tunnel packets.
///
/// Every query gets a fresh transaction id so that queries coming from
/// different apps can share a single upstream socket without collisions.
/// All methods must be called on `queue`.
final class DNSForwarder {
    private struct Pending {
        let original: IPv4UDPPacket
        let clientID: UInt16
        let sentAt: DispatchTime
    }

    private static let queryTimeout: DispatchTimeInterval = .seconds(4)
    private static let maxConsecutiveTimeouts = 3

    private let servers: [String]
    private let queue: DispatchQueue
    private let onResponse: ([UInt8]) -> Void
    private let logger = Logger(subsystem: "AdBlock", category: "DNSForwarder")

    private var serverIndex = 0
    private var connection: NWConnection?
    private var pending: [UInt16: Pending] = [:]
    private var nextID = UInt16.random(in: .min ... .max)
    private var consecutiveTimeouts = 0
    private var timer: DispatchSourceTimer?

    init(servers: [String], queue: DispatchQueue, onResponse: @escaping ([UInt8]) -> Void) {
        self.servers = servers.isEmpty ? ["1.1.1.1"] : servers
        self.queue = queue
        self.onResponse = onResponse
    }

    func start() {
        connect()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.expireTimedOutQueries() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        pending.removeAll()
    }

    func reconnect() {
        connection?.cancel()
        connection = nil
        connect()
    }

    func forward(query: [UInt8], original: IPv4UDPPacket) {
        guard let clientID = DNSMessage.transactionID(query) else { return }
        if connection == nil { connect() }

        var id = nextID
        while pending[id] != nil { id &+= 1 }
        nextID = id &+ 1
        pending[id] = Pending(original: original, clientID: clientID, sentAt: .now())

        let payload = Data(DNSMessage.replacingID(query, with: id))
        connection?.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            self?.logger.error("Send failed: \(error.localizedDescription, privacy: .public)")
        })
    }

    // MARK: - Private

    private func connect() {
        let server = servers[serverIndex % servers.count]
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            switch state {
            case .failed(let error):
                self.logger.error("Upstream \(server, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self.rotateServer()
            case .ready:
                self.logger.info("Upstream \(server, privacy: .public) ready")
            default:
                break
            }
        }
        connection.betterPathUpdateHandler = { [weak self, weak connection] better in
            guard better, let self, connection === self.connection else { return }
            self.reconnect()
        }
        self.connection = connection
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, connection === self.connection else { return }
            if let data, !data.isEmpty {
                self.handleResponse([UInt8](data))
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private func handleResponse(_ response: [UInt8]) {
        guard let id = DNSMessage.transactionID(response), let request = pending.removeValue(forKey: id) else { return }
        consecutiveTimeouts = 0
        let reply = DNSMessage.replacingID(response, with: request.clientID)
        onResponse(DNSPacketFilter.responsePacket(for: request.original, reply: reply))
    }

    private func expireTimedOutQueries() {
        let deadline = DispatchTime.now() - Self.queryTimeout
        let expired = pending.filter { $0.value.sentAt < deadline }
        guard !expired.isEmpty else { return }
        for id in expired.keys { pending.removeValue(forKey: id) }

        // The client's resolver retries on its own; we only switch server
        // when the current one looks dead (e.g. after a network change).
        consecutiveTimeouts += expired.count
        if consecutiveTimeouts >= Self.maxConsecutiveTimeouts {
            consecutiveTimeouts = 0
            rotateServer()
        }
    }

    private func rotateServer() {
        serverIndex = (serverIndex + 1) % servers.count
        reconnect()
    }
}
