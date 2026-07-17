import Foundation

/// The bidichan channel kinds.
public enum ChannelKind: String, CaseIterable, Codable {
    case forward, http, socks5, tun, shell
}

/// Which side hosts the listener / tun. "local" = this device.
public enum Side: String, CaseIterable, Codable {
    case local, remote
}

/// Builders for the bidichan daemon control-request JSON (the same schema the
/// CLI control socket speaks: {"action":"...","args":{...}}). These strings are
/// handed to the extension, which forwards them to the embedded Go core via
/// `MobileClient.control`.
public enum Control {
    private struct Req<A: Encodable>: Encodable {
        let action: String
        let args: A?
    }
    private struct NoArgs: Encodable {}

    private static func encode<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    public static func status() -> String { encode(Req<NoArgs>(action: "status", args: nil)) }

    public struct ForwardArgs: Encodable {
        public var listenSide: String
        public var listenAddr: String
        public var targetAddr: String
        public var label: String?
        public init(listenSide: Side, listenAddr: String, targetAddr: String, label: String? = nil) {
            self.listenSide = listenSide.rawValue
            self.listenAddr = listenAddr
            self.targetAddr = targetAddr
            self.label = label
        }
    }
    public static func openForward(_ a: ForwardArgs) -> String { encode(Req(action: "open_forward", args: a)) }

    public struct ProxyArgs: Encodable {
        public var listenSide: String
        public var listenAddr: String
        public var label: String?
        public init(listenSide: Side, listenAddr: String, label: String? = nil) {
            self.listenSide = listenSide.rawValue
            self.listenAddr = listenAddr
            self.label = label
        }
    }
    public static func openHTTP(_ a: ProxyArgs) -> String { encode(Req(action: "open_http", args: a)) }
    public static func openSocks5(_ a: ProxyArgs) -> String { encode(Req(action: "open_socks5", args: a)) }

    public struct TUNArgs: Encodable {
        public var tunSide: String
        public var cidr: String
        public var cidr6: String?
        public var mtu: Int
        public var name: String?
        public var label: String?
        public init(tunSide: Side = .local, cidr: String, cidr6: String? = nil, mtu: Int,
                    name: String? = nil, label: String? = nil) {
            self.tunSide = tunSide.rawValue
            self.cidr = cidr
            self.cidr6 = cidr6
            self.mtu = mtu
            self.name = name
            self.label = label
        }
    }
    public static func openTUN(_ a: TUNArgs) -> String { encode(Req(action: "open_tun", args: a)) }

    public struct CloseArgs: Encodable {
        public var channelId: UInt64
        public init(channelID: UInt64) { self.channelId = channelID }
    }
    public static func close(channelID: UInt64) -> String {
        encode(Req(action: "close_channel", args: CloseArgs(channelID: channelID)))
    }
}

/// Decoders for the bidichan control-response JSON ({"data":...} or {"error":...}).
public enum ControlDecode {
    public enum ControlError: Error, LocalizedError {
        case remote(String)
        public var errorDescription: String? {
            switch self { case .remote(let m): return m }
        }
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private struct Envelope<T: Decodable>: Decodable {
        let error: String?
        let data: T?
    }

    public static func status(_ json: String) throws -> StatusResponse {
        let env = try decoder().decode(Envelope<StatusResponse>.self, from: Data(json.utf8))
        if let e = env.error { throw ControlError.remote(e) }
        return env.data ?? StatusResponse(peers: [])
    }

    private struct OpenData: Decodable { let channelId: UInt64 }
    @discardableResult
    public static func open(_ json: String) throws -> UInt64 {
        let env = try decoder().decode(Envelope<OpenData>.self, from: Data(json.utf8))
        if let e = env.error { throw ControlError.remote(e) }
        return env.data?.channelId ?? 0
    }

    public static func ok(_ json: String) throws {
        struct E: Decodable { let error: String? }
        if let e = try decoder().decode(E.self, from: Data(json.utf8)).error {
            throw ControlError.remote(e)
        }
    }
}

// MARK: - Response models (mirror internal/daemon/ctrl.go + internal/peer)

public struct ChannelSnapshot: Decodable, Identifiable, Equatable, Hashable {
    public let id: UInt64
    public let kind: String
    public let originator: Bool
    public let createdAt: String
    public let description: String
    // Optional: older cores omit it, and not every channel carries a label.
    public let label: String?
}

public struct PeerStatus: Decodable, Identifiable, Equatable {
    public let id: String
    public let remote: String
    public let local: String
    public let startedAt: String
    public let mode: String
    public let channels: [ChannelSnapshot]?
}

public struct StatusResponse: Decodable, Equatable {
    public let peers: [PeerStatus]?
    public init(peers: [PeerStatus]?) { self.peers = peers }
}
