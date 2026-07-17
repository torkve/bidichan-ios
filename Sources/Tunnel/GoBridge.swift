import Foundation
import Bidichan

// GoBridge is the ONLY place that touches the gomobile-generated `Mobile*` API.
// Names/signatures below are matched to the generated Mobile.objc.h:
//   - constructors return optionals (MobileNewClient/MobileNewConfig)
//   - the Swift protocol for the PacketFlow interface is MobilePacketFlowProtocol
//     (the bare MobilePacketFlow is gomobile's own class)
//   - BOOL/nullable-return methods bridge to Swift `throws`; `control` returns a
//     nonnull String so it keeps an explicit `error:` pointer instead.

/// Wraps a gomobile `MobileClient` (the embedded bidichan connect-side daemon).
final class GoBridge {
    private let client: MobileClient

    init() {
        // MobileNewClient wraps a Go pointer and never returns nil in practice.
        client = MobileNewClient()!
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
        guard let cfg = MobileNewConfig() else {
            throw NSError(domain: "torkve.bidichan", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "failed to create config"])
        }
        cfg.addr = addr
        cfg.hostname = hostname
        cfg.pskHex = pskHex
        cfg.path = path
        cfg.noTLSBinding = noTLSBinding
        cfg.caCertPEM = caCertPEM
        cfg.fingerprint = fingerprint
        cfg.memoryLimitMB = memoryLimitMB
        try client.start(cfg, flow: flow)
    }

    /// Forwards a bidichan control request (JSON) and returns the JSON response.
    func control(_ json: String) throws -> String {
        var err: NSError?
        let result = client.control(json, error: &err)
        if let err { throw err }
        return result
    }

    /// Opens an interactive shell channel and returns a session handle.
    func openShell(term: String, rows: Int, cols: Int) throws -> GoShell {
        GoShell(session: try client.openShell(term, rows: rows, cols: cols))
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
