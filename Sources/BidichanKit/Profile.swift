import Foundation
import Combine

/// A connection profile. All fields here are non-secret and persisted in the
/// App Group container; the PSK is stored separately in the Keychain, keyed by
/// `pskAccount`.
public struct Profile: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var serverAddress: String   // host:port, e.g. "ws.example.com:443"
    public var hostname: String        // SNI + Host header
    public var path: String            // WS path; empty derives from the PSK
    public var noTLSBinding: Bool       // true behind a TLS-terminating proxy
    public var fingerprint: String      // "ios" | "safari" | "chrome"
    public var caCertPEM: String        // optional PEM to pin; empty = system roots

    // TUN / system-tunnel settings.
    public var enableTUN: Bool
    public var tunCIDR: String          // this device's IPv4 address, e.g. "10.42.0.2/24"
    // Default on the property (not just the init) so existing saved profiles that
    // predate this field still decode (synthesized Decodable uses it for the
    // missing key) instead of failing and dropping the profile list.
    public var tunCIDR6: String = "fd00:bd::2/64"   // device IPv6 (ULA); empty = no IPv6
    public var tunMTU: Int
    public var fullTunnel: Bool         // route all traffic vs just the tun subnet
    public var memoryLimitMB: Int       // soft Go heap cap inside the NE

    // Channels opened automatically once this profile connects. Property-level
    // default keeps older saved profiles (which lack the key) decodable.
    public var channels: [ChannelConfig] = []

    public init(id: UUID = UUID(),
                name: String = "New profile",
                serverAddress: String = "",
                hostname: String = "",
                path: String = "",
                noTLSBinding: Bool = true,
                fingerprint: String = "ios",
                caCertPEM: String = "",
                enableTUN: Bool = true,
                tunCIDR: String = "10.42.0.2/24",
                tunCIDR6: String = "fd00:bd::2/64",
                tunMTU: Int = 1400,
                fullTunnel: Bool = false,
                memoryLimitMB: Int = 40,
                channels: [ChannelConfig] = []) {
        self.id = id
        self.name = name
        self.serverAddress = serverAddress
        self.hostname = hostname
        self.path = path
        self.noTLSBinding = noTLSBinding
        self.fingerprint = fingerprint
        self.caCertPEM = caCertPEM
        self.enableTUN = enableTUN
        self.tunCIDR = tunCIDR
        self.tunCIDR6 = tunCIDR6
        self.tunMTU = tunMTU
        self.fullTunnel = fullTunnel
        self.memoryLimitMB = memoryLimitMB
        self.channels = channels
    }

    /// Keychain account under which this profile's PSK is stored.
    public var pskAccount: String { "psk-\(id.uuidString)" }
}

/// Loads and persists the profile list in the shared App Group container.
public final class ProfileStore: ObservableObject {
    @Published public private(set) var profiles: [Profile] = []
    private let url: URL

    public init() {
        url = AppGroup.containerURL.appendingPathComponent("profiles.json")
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func upsert(_ profile: Profile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        persist()
    }

    public func delete(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        Keychain.delete(account: profile.pskAccount)
        persist()
    }

    public func psk(for profile: Profile) -> String? {
        Keychain.get(account: profile.pskAccount)
    }

    public func setPSK(_ hex: String, for profile: Profile) throws {
        try Keychain.set(hex, account: profile.pskAccount)
    }
}
