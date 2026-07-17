import Foundation

/// A channel to open automatically when a profile connects. It captures the same
/// choices the "Add channel" sheet offers — kind, bind interface, port, and (for
/// forwards) a target — plus a user label and, for proxies, whether to publish it
/// to the system. Persisted inside `Profile`, so it is `Codable`.
public struct ChannelConfig: Codable, Identifiable, Equatable, Hashable {
    /// The user-facing channel kinds. Mirrors what the daemon can open; a forward
    /// splits into local-listen (`-L`) and remote-listen (`-R`) variants.
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        case socks5, http, forwardLocal, forwardRemote
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .socks5: return "SOCKS5 proxy"
            case .http: return "HTTP proxy"
            case .forwardLocal: return "Port forward (-L)"
            case .forwardRemote: return "Port forward (-R)"
            }
        }

        public var isProxy: Bool { self == .socks5 || self == .http }
        public var isForward: Bool { !isProxy }

        /// Which side hosts the listener. Only the remote forward listens on the peer.
        public var side: Side { self == .forwardRemote ? .remote : .local }

        /// The daemon proxy kind ("http"/"socks5"); undefined for forwards.
        public var proxyKind: String { self == .http ? "http" : "socks5" }

        public var defaultPort: Int {
            switch self {
            case .socks5: return 1080
            case .http: return 3128
            case .forwardLocal, .forwardRemote: return 8080
            }
        }
    }

    public var id: UUID
    public var label: String
    public var kind: Kind
    public var allInterfaces: Bool   // false = loopback (127.0.0.1)
    public var port: Int
    public var target: String        // "host:port"; forward only
    public var routeSystem: Bool      // proxy only: publish to iOS as the system proxy

    public init(id: UUID = UUID(),
                label: String = "",
                kind: Kind = .http,
                allInterfaces: Bool = false,
                port: Int = 3128,
                target: String = "127.0.0.1:80",
                routeSystem: Bool = true) {
        self.id = id
        self.label = label
        self.kind = kind
        self.allInterfaces = allInterfaces
        self.port = port
        self.target = target
        self.routeSystem = routeSystem
    }

    /// Tolerant decoder, for the same reason as `Profile`'s: synthesized
    /// `Decodable` ignores property defaults, so decoding every field with
    /// `decodeIfPresent ?? default` keeps a saved profile's channels from being
    /// dropped when we later add a field here. `id` is the only required key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .http
        allInterfaces = try c.decodeIfPresent(Bool.self, forKey: .allInterfaces) ?? false
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? kind.defaultPort
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? "127.0.0.1:80"
        routeSystem = try c.decodeIfPresent(Bool.self, forKey: .routeSystem) ?? true
    }

    /// The bind host implied by `allInterfaces`.
    public var host: String { allInterfaces ? "0.0.0.0" : "127.0.0.1" }

    /// The composed listen address handed to the daemon.
    public var listenAddr: String { "\(host):\(port)" }

    /// A non-empty label, falling back to a description of the channel.
    public var displayName: String {
        if !label.isEmpty { return label }
        return kind.isProxy ? "\(kind.proxyKind) :\(port)" : "\(kind.title) :\(port)"
    }
}
