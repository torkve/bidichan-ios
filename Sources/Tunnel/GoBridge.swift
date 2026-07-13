import Foundation
import Bidichan

// GoBridge is the ONLY place that touches the gomobile-generated `Mobile*` API.
// If the generated symbol names differ once `Bidichan.xcframework` is built by
// CI (verify against the generated module interface / `Bidichan-Swift.h`),
// adjust them here only.
//
// gomobile naming rules (package `mobile`, prefix `Mobile`, first letter of
// members lower-cased): `func NewClient()` -> `MobileNewClient()`, type
// `Client` -> `MobileClient`, `Config.PSKHex` -> `config.pSKHex`,
// `Config.CACertPEM` -> `config.cACertPEM`, and `(T, error)` returns map to
// throwing Swift methods.

/// Wraps a gomobile `MobileClient` (the embedded bidichan connect-side daemon).
final class GoBridge {
    private let client: MobileClient

    init() {
        client = MobileNewClient()
    }

    /// Starts the peer connection, blocking until the peer is up or the attempt
    /// fails. Must be called off the main thread.
    func start(addr: String,
               hostname: String,
               pskHex: String,
               path: String,
               noTLSBinding: Bool,
               caCertPEM: Data,
               fingerprint: String,
               memoryLimitMB: Int,
               flow: PacketFlowBridge) throws {
        let cfg = MobileNewConfig()
        cfg.addr = addr
        cfg.hostname = hostname
        cfg.pSKHex = pskHex            // Go: Config.PSKHex
        cfg.path = path
        cfg.noTLSBinding = noTLSBinding // Go: Config.NoTLSBinding
        cfg.cACertPEM = caCertPEM       // Go: Config.CACertPEM
        cfg.fingerprint = fingerprint
        cfg.memoryLimitMB = memoryLimitMB
        try client.start(cfg, flow: flow)
    }

    /// Forwards a bidichan control request (JSON) and returns the JSON response.
    func control(_ json: String) throws -> String {
        try client.control(json)
    }

    /// Opens an interactive shell channel and returns a session handle.
    func openShell(term: String, rows: Int, cols: Int) throws -> GoShell {
        let session = try client.openShell(term, rows: rows, cols: cols)
        return GoShell(session: session)
    }

    /// Blocks until the session ends; returns the reason (nil = clean shutdown).
    func waitUntilDone() -> String? {
        do {
            try client.wait()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func stop() {
        try? client.stop()
    }
}

/// Wraps a gomobile `MobileShellSession`.
final class GoShell {
    private let session: MobileShellSession

    init(session: MobileShellSession) {
        self.session = session
    }

    /// Blocks until shell output is available; throws when the shell ends.
    func read() throws -> Data { try session.read() }

    func write(_ data: Data) throws { try session.write(data) }

    func resize(rows: Int, cols: Int) throws { try session.resize(rows, cols: cols) }

    func close() { try? session.close() }
}
