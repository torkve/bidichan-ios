import Foundation

/// Request carried from the app to the tunnel extension over
/// `NETunnelProviderSession.sendProviderMessage`. Encoded as JSON.
public struct TunnelRequest: Codable {
    public enum Op: String, Codable {
        case control        // forward reqJSON to the Go core's control API
        case shellOpen
        case shellRead      // long-poll: the extension replies when output arrives
        case shellWrite
        case shellResize
        case shellClose
        case setSystemProxy   // publish a local proxy to the system via NEProxySettings
        case clearSystemProxy
        case ping
    }

    public var op: Op
    public var reqJSON: String?
    public var shellID: String?
    public var term: String?
    public var rows: Int?
    public var cols: Int?
    public var dataBase64: String?
    public var proxyKind: String?   // "http" | "socks5"
    public var proxyHost: String?
    public var proxyPort: Int?

    public init(op: Op, reqJSON: String? = nil, shellID: String? = nil,
                term: String? = nil, rows: Int? = nil, cols: Int? = nil,
                dataBase64: String? = nil, proxyKind: String? = nil,
                proxyHost: String? = nil, proxyPort: Int? = nil) {
        self.op = op
        self.reqJSON = reqJSON
        self.shellID = shellID
        self.term = term
        self.rows = rows
        self.cols = cols
        self.dataBase64 = dataBase64
        self.proxyKind = proxyKind
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
    }

    public static func control(_ json: String) -> TunnelRequest { .init(op: .control, reqJSON: json) }
    public static func ping() -> TunnelRequest { .init(op: .ping) }
    public static func shellOpen(term: String, rows: Int, cols: Int) -> TunnelRequest {
        .init(op: .shellOpen, term: term, rows: rows, cols: cols)
    }
    public static func shellRead(_ id: String) -> TunnelRequest { .init(op: .shellRead, shellID: id) }
    public static func shellWrite(_ id: String, base64: String) -> TunnelRequest {
        .init(op: .shellWrite, shellID: id, dataBase64: base64)
    }
    public static func shellResize(_ id: String, rows: Int, cols: Int) -> TunnelRequest {
        .init(op: .shellResize, shellID: id, rows: rows, cols: cols)
    }
    public static func shellClose(_ id: String) -> TunnelRequest { .init(op: .shellClose, shellID: id) }
    public static func setSystemProxy(kind: String, host: String, port: Int) -> TunnelRequest {
        .init(op: .setSystemProxy, proxyKind: kind, proxyHost: host, proxyPort: port)
    }
    public static func clearSystemProxy() -> TunnelRequest { .init(op: .clearSystemProxy) }
}

/// Reply from the tunnel extension to the app.
public struct TunnelResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var respJSON: String?     // bidichan control-response JSON (op == .control)
    public var shellID: String?      // op == .shellOpen
    public var dataBase64: String?   // op == .shellRead
    public var eof: Bool?            // op == .shellRead, set when the shell ended

    public init(ok: Bool, error: String? = nil, respJSON: String? = nil,
                shellID: String? = nil, dataBase64: String? = nil, eof: Bool? = nil) {
        self.ok = ok
        self.error = error
        self.respJSON = respJSON
        self.shellID = shellID
        self.dataBase64 = dataBase64
        self.eof = eof
    }

    public static func failure(_ message: String) -> TunnelResponse { .init(ok: false, error: message) }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data("{}".utf8) }
}
