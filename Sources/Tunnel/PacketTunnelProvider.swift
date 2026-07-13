import NetworkExtension
import BidichanKit

/// The Packet Tunnel Provider: hosts the embedded bidichan Go core, brings up
/// the peer connection, applies network settings from the profile's tun CIDR,
/// bridges packets, and relays control/shell requests from the app.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var bridge: GoBridge?
    private var flowBridge: PacketFlowBridge?

    private let shellsLock = NSLock()
    private var shells: [String: GoShell] = [:]

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let conf = proto.providerConfiguration else {
            completionHandler(providerError("missing provider configuration"))
            return
        }

        typealias K = BidichanConstants.Key
        let addr = string(conf, K.addr)
        let hostname = string(conf, K.hostname)
        let path = string(conf, K.path)
        let noTLSBinding = bool(conf, K.noTLSBinding, default: true)
        let fingerprint = string(conf, K.fingerprint, default: "ios")
        let caPEM = string(conf, K.caCertPEM)
        let enableTUN = bool(conf, K.enableTUN, default: true)
        let cidr = string(conf, K.tunCIDR, default: "10.42.0.2/24")
        let mtu = int(conf, K.tunMTU, default: 1400)
        let fullTunnel = bool(conf, K.fullTunnel, default: false)
        let memMB = int(conf, K.memoryLimitMB, default: 40)
        let profileID = string(conf, K.profileID)

        guard let psk = Keychain.get(account: "psk-\(profileID)"), !psk.isEmpty else {
            completionHandler(providerError("PSK not found in keychain for this profile"))
            return
        }

        let flowBridge = PacketFlowBridge(flow: packetFlow)
        self.flowBridge = flowBridge
        let bridge = GoBridge()
        self.bridge = bridge

        // Start blocks until the peer is up; run it off the provider's thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try bridge.start(addr: addr, hostname: hostname, pskHex: psk, path: path,
                                 noTLSBinding: noTLSBinding, caCertPEM: Data(caPEM.utf8),
                                 fingerprint: fingerprint, memoryLimitMB: memMB, flow: flowBridge)
            } catch {
                completionHandler(error)
                return
            }

            let server = hostname.isEmpty ? host(fromAddr: addr) : hostname
            self.applyTunnelSettings(cidr: cidr, mtu: mtu, fullTunnel: enableTUN && fullTunnel,
                                     server: server) { settingsErr in
                if let settingsErr {
                    completionHandler(settingsErr)
                    return
                }
                if enableTUN {
                    // packetFlow is live now; open the tun channel so the Go
                    // factory wires our PacketFlowBridge in.
                    do {
                        let json = Control.openTUN(.init(cidr: cidr, mtu: mtu))
                        try ControlDecode.open(try bridge.control(json))
                    } catch {
                        completionHandler(error)
                        return
                    }
                }
                self.startWaitLoop()
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        shellsLock.lock()
        shells.values.forEach { $0.close() }
        shells.removeAll()
        shellsLock.unlock()

        try? flowBridge?.close()
        bridge?.stop()
        bridge = nil
        flowBridge = nil
        completionHandler()
    }

    /// Watches the Go session; when the peer drops, tears the tunnel down.
    private func startWaitLoop() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let bridge = self.bridge else { return }
            let reason = bridge.waitUntilDone()
            self.cancelTunnelWithError(reason.map { self.providerError($0) })
        }
    }

    // MARK: - App messages

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler else { return }
        guard let req = try? JSONDecoder().decode(TunnelRequest.self, from: messageData) else {
            completionHandler(TunnelResponse.failure("malformed request").encoded())
            return
        }
        switch req.op {
        case .ping:
            completionHandler(TunnelResponse(ok: true).encoded())
        case .control:
            handleControl(req, completionHandler)
        case .shellOpen:
            handleShellOpen(req, completionHandler)
        case .shellRead:
            handleShellRead(req, completionHandler)
        case .shellWrite:
            handleShellWrite(req, completionHandler)
        case .shellResize:
            handleShellResize(req, completionHandler)
        case .shellClose:
            handleShellClose(req, completionHandler)
        }
    }

    private func handleControl(_ req: TunnelRequest, _ done: @escaping (Data?) -> Void) {
        guard let bridge, let json = req.reqJSON else {
            done(TunnelResponse.failure("tunnel not running").encoded())
            return
        }
        // control() can block briefly (open handshake); keep it off any UI path.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let resp = try bridge.control(json)
                done(TunnelResponse(ok: true, respJSON: resp).encoded())
            } catch {
                done(TunnelResponse.failure(error.localizedDescription).encoded())
            }
        }
    }

    private func handleShellOpen(_ req: TunnelRequest, _ done: @escaping (Data?) -> Void) {
        guard let bridge else {
            done(TunnelResponse.failure("tunnel not running").encoded())
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let shell = try bridge.openShell(term: req.term ?? "xterm-256color",
                                                 rows: req.rows ?? 24, cols: req.cols ?? 80)
                let id = UUID().uuidString
                self.shellsLock.lock()
                self.shells[id] = shell
                self.shellsLock.unlock()
                done(TunnelResponse(ok: true, shellID: id).encoded())
            } catch {
                done(TunnelResponse.failure(error.localizedDescription).encoded())
            }
        }
    }

    private func handleShellRead(_ req: TunnelRequest, _ done: @escaping (Data?) -> Void) {
        guard let id = req.shellID, let shell = shell(id) else {
            done(TunnelResponse(ok: true, eof: true).encoded())
            return
        }
        // Long-poll: read() blocks until output arrives or the shell ends.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try shell.read()
                done(TunnelResponse(ok: true, dataBase64: data.base64EncodedString()).encoded())
            } catch {
                self.removeShell(id)
                done(TunnelResponse(ok: true, eof: true).encoded())
            }
        }
    }

    private func handleShellWrite(_ req: TunnelRequest, _ done: @escaping (Data?) -> Void) {
        guard let id = req.shellID, let shell = shell(id) else {
            done(TunnelResponse.failure("no such shell").encoded())
            return
        }
        guard let b64 = req.dataBase64, let data = Data(base64Encoded: b64) else {
            done(TunnelResponse(ok: true).encoded())
            return
        }
        do {
            try shell.write(data)
            done(TunnelResponse(ok: true).encoded())
        } catch {
            done(TunnelResponse.failure(error.localizedDescription).encoded())
        }
    }

    private func handleShellResize(_ req: TunnelRequest, _ done: @escaping (Data?) -> Void) {
        guard let id = req.shellID, let shell = shell(id) else {
            done(TunnelResponse.failure("no such shell").encoded())
            return
        }
        try? shell.resize(rows: req.rows ?? 24, cols: req.cols ?? 80)
        done(TunnelResponse(ok: true).encoded())
    }

    private func handleShellClose(_ req: TunnelRequest, _ done: @escaping (Data?) -> Void) {
        if let id = req.shellID {
            shell(id)?.close()
            removeShell(id)
        }
        done(TunnelResponse(ok: true).encoded())
    }

    private func shell(_ id: String) -> GoShell? {
        shellsLock.lock(); defer { shellsLock.unlock() }
        return shells[id]
    }

    private func removeShell(_ id: String) {
        shellsLock.lock(); shells[id] = nil; shellsLock.unlock()
    }

    // MARK: - Network settings

    private func applyTunnelSettings(cidr: String, mtu: Int, fullTunnel: Bool,
                                     server: String,
                                     completion: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: server.isEmpty ? "127.0.0.1" : server)
        settings.mtu = NSNumber(value: mtu)

        if let info = CIDRInfo(cidr) {
            if info.isV6 {
                let v6 = NEIPv6Settings(addresses: [info.address],
                                        networkPrefixLengths: [NSNumber(value: info.prefix)])
                v6.includedRoutes = fullTunnel
                    ? [NEIPv6Route.default()]
                    : [NEIPv6Route(destinationAddress: info.address,
                                   networkPrefixLength: NSNumber(value: info.prefix))]
                settings.ipv6Settings = v6
            } else {
                let v4 = NEIPv4Settings(addresses: [info.address], subnetMasks: [info.subnetMask])
                v4.includedRoutes = fullTunnel
                    ? [NEIPv4Route.default()]
                    : [NEIPv4Route(destinationAddress: info.network, subnetMask: info.subnetMask)]
                settings.ipv4Settings = v4
            }
        }
        if fullTunnel {
            settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        }
        setTunnelNetworkSettings(settings, completionHandler: completion)
    }

    // MARK: - Helpers

    private func providerError(_ message: String) -> NSError {
        NSError(domain: "torkve.bidichan.tunnel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func string(_ c: [String: Any], _ key: String, default def: String = "") -> String {
        c[key] as? String ?? def
    }
    private func bool(_ c: [String: Any], _ key: String, default def: Bool) -> Bool {
        c[key] as? Bool ?? def
    }
    private func int(_ c: [String: Any], _ key: String, default def: Int) -> Int {
        if let n = c[key] as? Int { return n }
        if let n = c[key] as? NSNumber { return n.intValue }
        return def
    }
}

private func host(fromAddr addr: String) -> String {
    // "host:port" -> "host" (leave bracketed IPv6 literals intact).
    if let idx = addr.lastIndex(of: ":"), !addr.hasSuffix("]") {
        return String(addr[..<idx])
    }
    return addr
}

/// Parsed CIDR: address, prefix, IPv4 subnet mask and network base.
struct CIDRInfo {
    let address: String
    let isV6: Bool
    let prefix: Int
    let subnetMask: String   // IPv4 only
    let network: String      // IPv4 network base for a split route

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
        let addr = String(parts[0])
        if addr.contains(":") {
            guard prefix >= 0, prefix <= 128 else { return nil }
            self.address = addr; self.isV6 = true; self.prefix = prefix
            self.subnetMask = ""; self.network = addr
            return
        }
        let octets = addr.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, prefix >= 0, prefix <= 32 else { return nil }
        let maskBits: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        let addrBits = octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        self.address = addr
        self.isV6 = false
        self.prefix = prefix
        self.subnetMask = CIDRInfo.ipv4(maskBits)
        self.network = CIDRInfo.ipv4(addrBits & maskBits)
    }

    private static func ipv4(_ v: UInt32) -> String {
        "\((v >> 24) & 0xff).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
    }
}
