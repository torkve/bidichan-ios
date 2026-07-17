import SwiftUI
import Combine
import NetworkExtension
import BidichanKit

/// App-wide view model: owns the profile store and tunnel manager, tracks tunnel
/// status, and drives channel operations via the extension.
@MainActor
final class AppModel: ObservableObject {
    @Published var store = ProfileStore()
    let tunnel = TunnelManager()

    @Published var status: NEVPNStatus = .invalid
    @Published var peers: [PeerStatus] = []
    @Published var errorMessage: String?

    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // Default channels captured at connect time, opened once we reach .connected.
    private var pendingDefaults: [ChannelConfig] = []

    init() {
        // ProfileStore is a nested ObservableObject; @Published var store only
        // fires on reassignment, so forward its changes to our own observers or
        // the list won't refresh until relaunch.
        store.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        tunnel.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] s in
                guard let self else { return }
                self.status = s
                if s == .connected {
                    self.startPolling()
                    // Open the profile's default channels once, after the daemon
                    // is up. Consume the list so a later reassert->connected
                    // transition doesn't reopen them.
                    if !self.pendingDefaults.isEmpty {
                        let defaults = self.pendingDefaults
                        self.pendingDefaults = []
                        Task { await self.openDefaultChannels(defaults) }
                    }
                } else {
                    self.stopPolling()
                }
                // On failure/drop the extension records why (NEVPNManager hides
                // the provider's Error); surface it once.
                if s == .disconnected || s == .invalid, let err = AppGroup.lastError() {
                    self.errorMessage = err
                    AppGroup.setLastError(nil)
                }
            }
            .store(in: &cancellables)
    }

    func onAppear() async {
        await tunnel.refresh()
    }

    var statusText: String {
        switch status {
        case .invalid: return "Not configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        @unknown default: return "Unknown"
        }
    }

    var isBusy: Bool { status == .connecting || status == .disconnecting || status == .reasserting }

    // MARK: - Connection

    func connect(_ profile: Profile) async {
        guard store.psk(for: profile) != nil else {
            errorMessage = "Set a PSK for this profile first."
            return
        }
        AppGroup.setLastError(nil)   // clear any stale failure from a prior attempt
        pendingDefaults = profile.channels
        do {
            try await tunnel.install(profile: profile)
            try tunnel.start()
        } catch {
            pendingDefaults = []
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        pendingDefaults = []
        tunnel.stop()
        peers = []
    }

    /// Opens a profile's configured default channels in order once connected,
    /// publishing the first proxy flagged for system routing.
    private func openDefaultChannels(_ configs: [ChannelConfig]) async {
        var appliedSystemProxy = false
        for c in configs {
            let label = c.label.isEmpty ? nil : c.label
            if c.kind.isProxy {
                await openProxy(c.kind == .http ? .http : .socks5,
                                side: .local, listen: c.listenAddr, label: label)
                if c.routeSystem && !appliedSystemProxy {
                    await setSystemProxy(kind: c.kind.proxyKind, host: "127.0.0.1", port: c.port)
                    appliedSystemProxy = true
                }
            } else {
                await openForward(side: c.kind.side, listen: c.listenAddr,
                                  target: c.target, label: label)
            }
        }
    }

    // MARK: - Channels

    func refreshStatus() async {
        do {
            let resp = try await tunnel.send(.control(Control.status()))
            if let json = resp.respJSON {
                peers = (try ControlDecode.status(json)).peers ?? []
            } else if let e = resp.error {
                _ = e // transient; don't spam the UI while (dis)connecting
            }
        } catch {
            // Ignore transient send failures during status transitions.
        }
    }

    /// The proxy currently published to the system via NEProxySettings, if any.
    struct SystemProxy: Equatable { var kind: String; var host: String; var port: Int }
    @Published var systemProxy: SystemProxy?

    func openProxy(_ kind: ChannelKind, side: Side, listen: String, label: String? = nil) async {
        let json = kind == .http
            ? Control.openHTTP(.init(listenSide: side, listenAddr: listen, label: label))
            : Control.openSocks5(.init(listenSide: side, listenAddr: listen, label: label))
        await control(json)
    }

    func openForward(side: Side, listen: String, target: String, label: String? = nil) async {
        await control(Control.openForward(.init(listenSide: side, listenAddr: listen, targetAddr: target, label: label)))
    }

    func openTUN(cidr: String, mtu: Int) async {
        await control(Control.openTUN(.init(cidr: cidr, mtu: mtu)))
    }

    /// Publishes a local proxy to the system (routes other apps through it).
    func setSystemProxy(kind: String, host: String, port: Int) async {
        do {
            let resp = try await tunnel.send(.setSystemProxy(kind: kind, host: host, port: port))
            if resp.ok {
                systemProxy = SystemProxy(kind: kind, host: host, port: port)
            } else {
                errorMessage = resp.error ?? "failed to set system proxy"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSystemProxy() async {
        do {
            _ = try await tunnel.send(.clearSystemProxy())
        } catch {
            // best effort; still clear locally
        }
        systemProxy = nil
    }

    func closeChannel(_ id: UInt64) async {
        await control(Control.close(channelID: id))
    }

    private func control(_ json: String) async {
        do {
            let resp = try await tunnel.send(.control(json))
            if let e = resp.error {
                errorMessage = e
            } else if let j = resp.respJSON {
                struct E: Decodable { let error: String? }
                if let decoded = try? JSONDecoder().decode(E.self, from: Data(j.utf8)),
                   let msg = decoded.error {
                    errorMessage = msg
                }
            }
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        peers = []
        systemProxy = nil   // extension state is gone once disconnected
    }
}
