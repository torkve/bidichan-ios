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

    // Stored so network settings can be rebuilt (e.g. to add/remove a system
    // proxy) after the tunnel is already up.
    private struct TunnelConfig {
        var cidr: String, cidr6: String, mtu: Int, fullTunnel: Bool, server: String
    }
    private var tunnelConfig: TunnelConfig?
    private var systemProxy: (kind: String, host: String, port: Int)?

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        AppLog.log("startTunnel: begin")
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let conf = proto.providerConfiguration else {
            fail("missing provider configuration", completionHandler)
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
        let cidr6 = string(conf, K.tunCIDR6)
        let mtu = int(conf, K.tunMTU, default: 1400)
        let fullTunnel = bool(conf, K.fullTunnel, default: false)
        let memMB = int(conf, K.memoryLimitMB, default: 40)
        let profileID = string(conf, K.profileID)

        AppLog.log("config: addr=\(addr) host=\(hostname) " +
                   "path=\(path.isEmpty ? "(psk-derived)" : path) noTLSBinding=\(noTLSBinding) " +
                   "fp=\(fingerprint) tun=\(enableTUN) cidr=\(cidr) mtu=\(mtu) full=\(fullTunnel) " +
                   "ca=\(caPEM.isEmpty ? "no" : "yes")")

        guard let psk = Keychain.get(account: "psk-\(profileID)"), !psk.isEmpty else {
            fail("PSK not found in keychain (profile id=\(profileID)) — app/extension keychain sharing?",
                 completionHandler)
            return
        }
        AppLog.log("psk: loaded (\(psk.count) hex chars)")

        let flowBridge = PacketFlowBridge(flow: packetFlow)
        self.flowBridge = flowBridge
        let bridge = GoBridge()
        self.bridge = bridge

        // Start blocks until the peer is up; run it off the provider's thread.
        DispatchQueue.global(qos: .userInitiated).async {
            AppLog.log("go start: dialing \(addr) …")
            do {
                try bridge.start(addr: addr, hostname: hostname, pskHex: psk, path: path,
                                 noTLSBinding: noTLSBinding, caCertPEM: Data(caPEM.utf8),
                                 fingerprint: fingerprint, memoryLimitMB: memMB, flow: flowBridge)
            } catch {
                self.fail("go start: \(error.localizedDescription)", completionHandler)
                return
            }
            AppLog.log("go start: peer up")

            // tunnelRemoteAddress must be a numeric IP, not a hostname.
            let serverIP = self.tunnelRemoteIP(bridge: bridge, addr: addr, hostname: hostname)
            AppLog.log("tunnel remote address: \(serverIP)")
            self.tunnelConfig = TunnelConfig(cidr: cidr, cidr6: cidr6, mtu: mtu,
                                             fullTunnel: enableTUN && fullTunnel, server: serverIP)
            self.rebuildAndApply { settingsErr in
                if let settingsErr {
                    self.fail("network settings: \(settingsErr.localizedDescription)", completionHandler)
                    return
                }
                AppLog.log("network settings: applied")
                if enableTUN {
                    // packetFlow is live now; open the tun channel so the Go
                    // factory wires our PacketFlowBridge in. Give the peer a
                    // DIFFERENT address in the subnet (the gateway) than our own
                    // device address — otherwise both ends share one address and
                    // return traffic is delivered to the peer locally.
                    let gwCIDR = Self.gatewayCIDR(fromDevice: cidr)
                    let gwCIDR6 = cidr6.isEmpty ? nil : Self.gatewayCIDR6(fromDevice: cidr6)
                    do {
                        let json = Control.openTUN(.init(cidr: gwCIDR, cidr6: gwCIDR6, mtu: mtu))
                        try ControlDecode.open(try bridge.control(json))
                        AppLog.log("tun channel: opened (device \(cidr)/\(cidr6.isEmpty ? "-" : cidr6), " +
                                   "gateway \(gwCIDR)/\(gwCIDR6 ?? "-"))")
                    } catch {
                        self.fail("open tun: \(error.localizedDescription)", completionHandler)
                        return
                    }
                }
                AppGroup.setLastError(nil)
                AppLog.log("startTunnel: connected")
                self.startWaitLoop()
                completionHandler(nil)
            }
        }
    }

    /// Logs the reason, records it as the shared last-error, and reports failure.
    private func fail(_ message: String, _ completion: @escaping (Error?) -> Void) {
        AppLog.log("startTunnel FAILED: \(message)")
        AppGroup.setLastError(message)
        completion(providerError(message))
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        AppLog.log("stopTunnel: reason=\(reason.rawValue)")
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
            AppLog.log("session ended: \(reason ?? "clean shutdown")")
            if let reason { AppGroup.setLastError(reason) }
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
        case .setSystemProxy:
            systemProxy = (req.proxyKind ?? "http", req.proxyHost ?? "127.0.0.1", req.proxyPort ?? 0)
            AppLog.log("system proxy: set \(systemProxy!.kind) \(systemProxy!.host):\(systemProxy!.port)")
            rebuildAndApply { err in
                completionHandler((err.map { TunnelResponse.failure($0.localizedDescription) }
                                   ?? TunnelResponse(ok: true)).encoded())
            }
        case .clearSystemProxy:
            systemProxy = nil
            AppLog.log("system proxy: cleared")
            rebuildAndApply { err in
                completionHandler((err.map { TunnelResponse.failure($0.localizedDescription) }
                                   ?? TunnelResponse(ok: true)).encoded())
            }
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

    /// Re-applies the tunnel settings built from the stored config (used both at
    /// startup and when the system proxy changes mid-session).
    private func rebuildAndApply(completion: @escaping (Error?) -> Void) {
        guard let settings = buildSettings() else {
            completion(providerError("no tunnel config"))
            return
        }
        setTunnelNetworkSettings(settings, completionHandler: completion)
    }

    private func buildSettings() -> NEPacketTunnelNetworkSettings? {
        guard let c = tunnelConfig else { return nil }
        let cidr = c.cidr, cidr6 = c.cidr6, mtu = c.mtu, fullTunnel = c.fullTunnel, server = c.server
        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: server.isEmpty ? "127.0.0.1" : server)
        settings.mtu = NSNumber(value: mtu)
        // Keep the peer connection off the tunnel it provides: exclude the
        // (runtime-resolved) server address in its own family so the WebSocket
        // can't loop.
        let serverIsV6 = server.contains(":")

        // IPv4
        if let info = CIDRInfo(cidr), !info.isV6 {
            let v4 = NEIPv4Settings(addresses: [info.address], subnetMasks: [info.subnetMask])
            v4.includedRoutes = fullTunnel
                ? [NEIPv4Route.default()]
                : [NEIPv4Route(destinationAddress: info.network, subnetMask: info.subnetMask)]
            if fullTunnel, !server.isEmpty, !serverIsV6 {
                v4.excludedRoutes = [NEIPv4Route(destinationAddress: server,
                                                 subnetMask: "255.255.255.255")]
            }
            settings.ipv4Settings = v4
        }

        // IPv6 (dual-stack)
        if !cidr6.isEmpty, let info6 = CIDRInfo(cidr6), info6.isV6 {
            let v6 = NEIPv6Settings(addresses: [info6.address],
                                    networkPrefixLengths: [NSNumber(value: info6.prefix)])
            v6.includedRoutes = fullTunnel
                ? [NEIPv6Route.default()]
                : [NEIPv6Route(destinationAddress: info6.address,
                               networkPrefixLength: NSNumber(value: info6.prefix))]
            if fullTunnel, !server.isEmpty, serverIsV6 {
                v6.excludedRoutes = [NEIPv6Route(destinationAddress: server,
                                                 networkPrefixLength: 128)]
            }
            settings.ipv6Settings = v6
        }

        if fullTunnel {
            var servers = ["1.1.1.1", "8.8.8.8"]
            if !cidr6.isEmpty { servers += ["2606:4700:4700::1111", "2001:4860:4860::8888"] }
            let dns = NEDNSSettings(servers: servers)
            dns.matchDomains = [""]   // use the tunnel resolver for all lookups
            settings.dnsSettings = dns
        }

        if let p = systemProxy {
            settings.proxySettings = makeProxySettings(kind: p.kind, host: p.host, port: p.port)
        }
        return settings
    }

    /// System proxy config the OS hands to apps. HTTP is set natively; SOCKS5 is
    /// expressed through a PAC (honored by apps that support PAC).
    private func makeProxySettings(kind: String, host: String, port: Int) -> NEProxySettings {
        let ps = NEProxySettings()
        if kind == "socks5" {
            ps.autoProxyConfigurationEnabled = true
            ps.proxyAutoConfigurationJavaScript =
                "function FindProxyForURL(url, host){return \"SOCKS5 \(host):\(port); " +
                "SOCKS \(host):\(port); DIRECT\";}"
        } else {
            let server = NEProxyServer(address: host, port: port)
            ps.httpEnabled = true
            ps.httpServer = server
            ps.httpsEnabled = true
            ps.httpsServer = server
        }
        ps.matchDomains = [""]
        return ps
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

extension PacketTunnelProvider {
    /// Resolves the tunnel's remote endpoint to a numeric IP (required by
    /// NEPacketTunnelNetworkSettings). Prefers the exact IP the peer connection
    /// resolved to (from status), then DNS, then the bare host as a last resort.
    func tunnelRemoteIP(bridge: GoBridge, addr: String, hostname: String) -> String {
        if let json = try? bridge.control(Control.status()),
           let remote = (try? ControlDecode.status(json))?.peers?.first?.remote {
            let ip = Self.stripPort(remote)
            if !ip.isEmpty { return ip }
        }
        let h = hostname.isEmpty ? Self.stripPort(addr) : hostname
        return Self.resolveIP(h) ?? h
    }

    /// A CIDR in the same IPv4 subnet as `deviceCIDR` but a different host, used
    /// for the peer's tun so the two ends don't share one address. Picks the
    /// first host (network+1), or the second if the device is already the first.
    /// Falls back to the input if it can't parse a v4 CIDR.
    static func gatewayCIDR(fromDevice deviceCIDR: String) -> String {
        let parts = deviceCIDR.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0, prefix <= 32 else {
            return deviceCIDR
        }
        let octets = parts[0].split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return deviceCIDR }
        let addr = octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        let network = addr & mask
        var gw = network | 1
        if gw == addr { gw = network | 2 }
        let s = "\((gw >> 24) & 0xff).\((gw >> 16) & 0xff).\((gw >> 8) & 0xff).\(gw & 0xff)"
        return "\(s)/\(prefix)"
    }

    /// IPv6 analogue of gatewayCIDR: same subnet, low-order byte set to 1 (or 2
    /// if the device already ends in 1). e.g. fd00:bd::2/64 -> fd00:bd::1/64.
    static func gatewayCIDR6(fromDevice cidr: String) -> String {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2 else { return cidr }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard inet_pton(AF_INET6, String(parts[0]), &bytes) == 1 else { return cidr }
        bytes[15] = (bytes[15] == 1) ? 2 : 1
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &bytes, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return cidr }
        return "\(String(cString: buf))/\(parts[1])"
    }

    /// "1.2.3.4:443" -> "1.2.3.4"; "[::1]:443" -> "::1"; "host" -> "host".
    static func stripPort(_ hostPort: String) -> String {
        if hostPort.hasPrefix("["), let end = hostPort.firstIndex(of: "]") {
            return String(hostPort[hostPort.index(after: hostPort.startIndex)..<end])
        }
        if let idx = hostPort.lastIndex(of: ":") {
            return String(hostPort[..<idx])
        }
        return hostPort
    }

    /// Resolves a host (or passes an IP literal through) to a numeric IP string.
    static func resolveIP(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                          &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: buf)
    }
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
