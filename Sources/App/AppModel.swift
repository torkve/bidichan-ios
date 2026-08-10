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
                switch s {
                case .connected:
                    self.startPolling()
                case .reasserting:
                    // The tunnel is still installed and the extension is still
                    // there — it is riding out a network change. Keep polling
                    // so the channel list survives the blip instead of blinking
                    // away and coming back.
                    self.startPolling()
                default:
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

    /// The tunnel is up as far as the user is concerned: either carrying
    /// traffic, or briefly reconnecting underneath while its channels — and
    /// the connections inside them — stay open.
    var isLive: Bool { status == .connected || status == .reasserting }

    // MARK: - Connection

    func connect(_ profile: Profile) async {
        guard store.psk(for: profile) != nil else {
            errorMessage = "Set a PSK for this profile first."
            return
        }
        AppGroup.setLastError(nil)   // clear any stale failure from a prior attempt
        do {
            // The profile's default channels travel with the configuration and
            // are opened by the extension, so they come up the same way whether
            // the tunnel was started here or from Settings.
            try await tunnel.install(profile: profile)
            try tunnel.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rewrites the tunnel configuration when the installed profile is edited,
    /// so a connection started from Settings uses the current settings. Skipped
    /// while the tunnel is up: replacing the configuration under a live tunnel
    /// is the system's business, and the edits apply on the next connect.
    func reinstallIfInstalled(_ profile: Profile) async {
        guard tunnel.activeProfileID == profile.id.uuidString, !isLive else { return }
        try? await tunnel.install(profile: profile)
    }

    func disconnect() {
        tunnel.stop()
        peers = []
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

    /// Asks the extension what it currently publishes as the system proxy. The
    /// extension may have set one itself from the profile's defaults, which the
    /// app would otherwise never learn about.
    private func refreshSystemProxy() async {
        guard let resp = try? await tunnel.send(.getSystemProxy()), resp.ok else { return }
        if let kind = resp.proxyKind, let host = resp.proxyHost, let port = resp.proxyPort {
            systemProxy = SystemProxy(kind: kind, host: host, port: port)
        } else {
            systemProxy = nil
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                await self?.refreshSystemProxy()
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
