import Foundation
import NetworkExtension
import Bidichan
import BidichanKit

/// Bridges the Packet Tunnel Provider's `NEPacketTunnelFlow` to the Go core's
/// `MobilePacketFlow`.
///
/// The Go tun channel frames exactly one IP packet per read (uint16 length
/// prefix), so `readPacket()` MUST return exactly one packet. `NEPacketTunnelFlow`
/// delivers packets asynchronously in batches, so we continuously read batches
/// into a queue and hand them out one at a time, blocking `readPacket()` when
/// the queue is empty. This is the critical correctness seam of the port.
final class PacketFlowBridge: NSObject, MobilePacketFlowProtocol {
    private let flow: NEPacketTunnelFlow
    private let cond = NSCondition()
    private var queue: [Data] = []
    private var closed = false

    // Diagnostic counters (outbound = device→peer via readPacket, inbound =
    // peer→device via writePacket), logged periodically so the Logs reveal
    // whether traffic leaves the device and whether replies come back.
    private let statsLock = NSLock()
    private var outPackets = 0, outBytes = 0, inPackets = 0, inBytes = 0
    private var statsTimer: DispatchSourceTimer?

    init(flow: NEPacketTunnelFlow) {
        self.flow = flow
        super.init()
        startStats()
        pump()
    }

    private func startStats() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 3, repeating: 3)
        var lastOut = 0, lastIn = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.statsLock.lock()
            let op = self.outPackets, ob = self.outBytes, ip = self.inPackets, ib = self.inBytes
            self.statsLock.unlock()
            if op != lastOut || ip != lastIn {
                AppLog.log("tun stats: out \(op) pkt/\(ob) B, in \(ip) pkt/\(ib) B " +
                           "(Δout \(op - lastOut), Δin \(ip - lastIn))")
                lastOut = op
                lastIn = ip
            }
        }
        t.resume()
        statsTimer = t
    }

    /// Reads one batch and re-arms itself for the next.
    private func pump() {
        flow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.cond.lock()
            let open = !self.closed
            if open {
                self.queue.append(contentsOf: packets)
                self.cond.signal()
            }
            self.cond.unlock()
            if open { self.pump() }
        }
    }

    // MARK: - MobilePacketFlow

    /// Returns exactly one outbound IP packet, blocking until one is available.
    func readPacket() throws -> Data {
        cond.lock()
        while queue.isEmpty && !closed { cond.wait() }
        defer { cond.unlock() }
        if !queue.isEmpty {
            let pkt = queue.removeFirst()
            statsLock.lock(); outPackets += 1; outBytes += pkt.count; statsLock.unlock()
            return pkt
        }
        throw NSError(domain: "torkve.bidichan.flow", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "packet flow closed"])
    }

    /// Injects one inbound IP packet toward the OS, tagging its address family
    /// from the IP version in the first nibble.
    func writePacket(_ p: Data?) throws {
        guard let p, let first = p.first else { return }
        let family: Int32 = (first >> 4) == 6 ? AF_INET6 : AF_INET
        flow.writePackets([p], withProtocols: [NSNumber(value: family)])
        statsLock.lock(); inPackets += 1; inBytes += p.count; statsLock.unlock()
    }

    func close() throws {
        statsTimer?.cancel()
        statsTimer = nil
        cond.lock()
        closed = true
        cond.signal()
        cond.unlock()
    }
}
