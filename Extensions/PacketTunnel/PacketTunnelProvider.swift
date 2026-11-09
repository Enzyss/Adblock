import AdBlockCore
import Foundation
import NetworkExtension
import os

/// System wide ad blocking for every app, implemented as a local DNS filter.
///
/// The tunnel only routes a single fake address (198.18.0.1) and declares it
/// as the device DNS server. Every DNS query from every app therefore arrives
/// here as a raw IP packet: blocked domains get a `0.0.0.0` answer, everything
/// else is forwarded to a real resolver. Normal traffic never enters the
/// tunnel, so speed and battery are unaffected and no data leaves the device
/// except plain DNS lookups to the chosen resolver.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let tunnelAddress = "198.18.0.2"
    private static let dnsAddress = "198.18.0.1"

    private let queue = DispatchQueue(label: "com.adblock.tunnel.dns")
    private let logger = Logger(subsystem: "AdBlock", category: "PacketTunnel")

    private var filter = DNSPacketFilter(blocklist: .empty)
    private var forwarder: DNSForwarder?
    private var activity = DNSActivity.load()
    private var activitySaveScheduled = false
    private var isRunning = false

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        queue.sync { reloadBlocklist() }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: [Self.tunnelAddress], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: Self.dnsAddress, subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: [Self.dnsAddress])
        dns.matchDomains = [""] // every domain goes through our resolver
        settings.dnsSettings = dns
        settings.mtu = 1_500

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("Failed to apply tunnel settings: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }
            self.queue.async {
                self.isRunning = true
                self.startForwarder()
                self.readPackets()
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.isRunning = false
            self.forwarder?.stop()
            self.forwarder = nil
            self.activity.save()
            completionHandler()
        }
    }

    override func wake() {
        // Network may have changed while the device was asleep.
        queue.async { self.forwarder?.reconnect() }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let message = String(data: messageData, encoding: .utf8).flatMap(TunnelMessage.init(rawValue:))
        queue.async {
            switch message {
            case .reloadBlocklist:
                self.reloadBlocklist()
                self.startForwarder()
            case .resetStatistics:
                self.activity = DNSActivity()
                self.activity.save()
            case nil:
                break
            }
            completionHandler?(Data("ok".utf8))
        }
    }

    // MARK: - Setup

    private func reloadBlocklist() {
        guard let data = try? Data(contentsOf: SharedContainer.dnsBlocklistURL),
              let blocklist = DomainBlocklist(serialized: data)
        else {
            logger.notice("No compiled DNS blocklist found, filtering is disabled until the app updates the lists")
            filter = DNSPacketFilter(blocklist: .empty)
            return
        }
        filter = DNSPacketFilter(blocklist: blocklist)
        logger.info("Loaded \(blocklist.count) blocked domains")
    }

    private func startForwarder() {
        forwarder?.stop()
        let forwarder = DNSForwarder(servers: UpstreamDNS.current.servers, queue: queue) { [weak self] packet in
            self?.write(packet)
        }
        forwarder.start()
        self.forwarder = forwarder
    }

    // MARK: - Packet loop

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.queue.async {
                guard self.isRunning else { return }
                for packet in packets {
                    self.handle(packet: [UInt8](packet))
                }
                self.readPackets()
            }
        }
    }

    private func handle(packet: [UInt8]) {
        switch filter.handle(packet: packet) {
        case let .blocked(domain, response):
            write(response)
            record(domain: domain, blocked: true)
        case let .forward(domain, query, original):
            forwarder?.forward(query: query, original: original)
            record(domain: domain, blocked: false)
        case .ignore:
            break
        }
    }

    private func write(_ packet: [UInt8]) {
        packetFlow.writePackets([Data(packet)], withProtocols: [NSNumber(value: AF_INET)])
    }

    // MARK: - Statistics

    private func record(domain: String, blocked: Bool) {
        activity.record(domain: domain, blocked: blocked)
        guard !activitySaveScheduled else { return }
        activitySaveScheduled = true
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.activitySaveScheduled = false
            self.activity.save()
        }
    }
}
