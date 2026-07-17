import Foundation
import Combine
import NetworkExtension

/// Owns the `NETunnelProviderManager` and drives the tunnel from the app:
/// installs/updates the tunnel configuration from a `Profile`, starts/stops it,
/// tracks status, and relays control requests to the extension.
@MainActor
public final class TunnelManager: ObservableObject {
    @Published public private(set) var status: NEVPNStatus = .invalid
    @Published public private(set) var activeProfileID: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    public init() {}

    public enum TunnelError: Error, LocalizedError {
        case noManager
        case notConnected
        case emptyResponse
        public var errorDescription: String? {
            switch self {
            case .noManager: return "the tunnel is not configured yet"
            case .notConnected: return "the tunnel is not running"
            case .emptyResponse: return "the tunnel returned no response"
            }
        }
    }

    /// Loads the existing manager (if any) so status reflects reality on launch.
    public func refresh() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        let m = managers.first
        manager = m
        activeProfileID = (m?.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?[BidichanConstants.Key.profileID] as? String
        status = m?.connection.status ?? .invalid
        if let m { observe(m) }
    }

    private func observe(_ m: NETunnelProviderManager) {
        if let o = statusObserver { NotificationCenter.default.removeObserver(o) }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: m.connection, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.status = m.connection.status }
        }
    }

    /// Writes the tunnel configuration for `profile` into preferences.
    public func install(profile: Profile) async throws {
        let m = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = BidichanConstants.tunnelBundleID
        proto.serverAddress = profile.serverAddress
        proto.providerConfiguration = [
            BidichanConstants.Key.profileID: profile.id.uuidString,
            BidichanConstants.Key.addr: profile.serverAddress,
            BidichanConstants.Key.hostname: profile.hostname,
            BidichanConstants.Key.path: profile.path,
            BidichanConstants.Key.noTLSBinding: profile.noTLSBinding,
            BidichanConstants.Key.fingerprint: profile.fingerprint,
            BidichanConstants.Key.caCertPEM: profile.caCertPEM,
            BidichanConstants.Key.enableTUN: profile.enableTUN,
            BidichanConstants.Key.tunCIDR: profile.tunCIDR,
            BidichanConstants.Key.tunCIDR6: profile.tunCIDR6,
            BidichanConstants.Key.tunMTU: profile.tunMTU,
            BidichanConstants.Key.fullTunnel: profile.fullTunnel,
            BidichanConstants.Key.memoryLimitMB: profile.memoryLimitMB,
        ]
        m.localizedDescription = "bidichan — \(profile.name)"
        m.protocolConfiguration = proto
        m.isEnabled = true
        try await m.saveToPreferences()
        // Reload so the connection object is valid for start / messaging.
        try await m.loadFromPreferences()
        manager = m
        activeProfileID = profile.id.uuidString
        status = m.connection.status
        observe(m)
    }

    public func start() throws {
        guard let m = manager else { throw TunnelError.noManager }
        try m.connection.startVPNTunnel()
    }

    public func stop() {
        manager?.connection.stopVPNTunnel()
    }

    /// Sends a request to the extension and awaits its response.
    public func send(_ request: TunnelRequest) async throws -> TunnelResponse {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            throw TunnelError.notConnected
        }
        let payload = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { cont in
            do {
                try session.sendProviderMessage(payload) { data in
                    guard let data else {
                        cont.resume(returning: .failure(TunnelError.emptyResponse.localizedDescription))
                        return
                    }
                    do {
                        cont.resume(returning: try JSONDecoder().decode(TunnelResponse.self, from: data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
