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
    public var tunCIDR6: String         // device IPv6 (ULA); empty = no IPv6
    public var tunMTU: Int
    public var fullTunnel: Bool         // route all traffic vs just the tun subnet
    public var memoryLimitMB: Int       // soft Go heap cap inside the NE

    // Channels opened automatically once this profile connects.
    public var channels: [ChannelConfig]

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

    /// Tolerant decoder. Swift's *synthesized* `Decodable` calls the throwing
    /// `decode(_:forKey:)` for every non-optional property and ignores property
    /// default values, so a saved profile that predates any field we later add
    /// would fail to decode — and `ProfileStore` would drop the whole list. We
    /// therefore decode every field with `decodeIfPresent ?? default`, so adding
    /// a field is always backward-compatible. `id` is the only required key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New profile"
        serverAddress = try c.decodeIfPresent(String.self, forKey: .serverAddress) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        noTLSBinding = try c.decodeIfPresent(Bool.self, forKey: .noTLSBinding) ?? true
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? "ios"
        caCertPEM = try c.decodeIfPresent(String.self, forKey: .caCertPEM) ?? ""
        enableTUN = try c.decodeIfPresent(Bool.self, forKey: .enableTUN) ?? true
        tunCIDR = try c.decodeIfPresent(String.self, forKey: .tunCIDR) ?? "10.42.0.2/24"
        tunCIDR6 = try c.decodeIfPresent(String.self, forKey: .tunCIDR6) ?? "fd00:bd::2/64"
        tunMTU = try c.decodeIfPresent(Int.self, forKey: .tunMTU) ?? 1400
        fullTunnel = try c.decodeIfPresent(Bool.self, forKey: .fullTunnel) ?? false
        memoryLimitMB = try c.decodeIfPresent(Int.self, forKey: .memoryLimitMB) ?? 40
        channels = try c.decodeIfPresent([ChannelConfig].self, forKey: .channels) ?? []
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
        guard let data = try? Data(contentsOf: url) else {
            profiles = []
            return
        }
        let dec = JSONDecoder()
        if let decoded = try? dec.decode([Profile].self, from: data) {
            profiles = decoded
            return
        }
        // The list as a whole didn't decode (corruption — schema drift is handled
        // by Profile's tolerant decoder). Keep the original bytes for recovery,
        // then salvage the entries that still parse instead of dropping them all.
        try? data.write(to: url.appendingPathExtension("bak"), options: .atomic)
        profiles = (try? dec.decode([FailableProfile].self, from: data))?.compactMap(\.value) ?? []
    }

    /// Decodes a profile without failing the surrounding array: a single bad
    /// entry becomes nil rather than aborting the whole `[Profile]` decode.
    private struct FailableProfile: Decodable {
        let value: Profile?
        init(from decoder: Decoder) throws { value = try? Profile(from: decoder) }
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
