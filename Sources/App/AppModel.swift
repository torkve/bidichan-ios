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
                if s == .connected { self.startPolling() } else { self.stopPolling() }
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
        do {
            try await tunnel.install(profile: profile)
            try tunnel.start()
        } catch {
            errorMessage = error.localizedDescription
        }
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

    func openSocks5(listen: String) async {
        await control(Control.openSocks5(.init(listenSide: .local, listenAddr: listen)))
    }

    func openHTTP(listen: String) async {
        await control(Control.openHTTP(.init(listenSide: .local, listenAddr: listen)))
    }

    func openForward(listen: String, target: String) async {
        await control(Control.openForward(.init(listenSide: .local, listenAddr: listen, targetAddr: target)))
    }

    func openTUN(cidr: String, mtu: Int) async {
        await control(Control.openTUN(.init(cidr: cidr, mtu: mtu)))
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
    }
}
