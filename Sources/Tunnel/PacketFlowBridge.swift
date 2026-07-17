import Foundation
import NetworkExtension
import Bidichan

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

    init(flow: NEPacketTunnelFlow) {
        self.flow = flow
        super.init()
        pump()
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
            return queue.removeFirst()
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
    }

    func close() throws {
        cond.lock()
        closed = true
        cond.signal()
        cond.unlock()
    }
}
