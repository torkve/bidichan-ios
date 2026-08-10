import Foundation
import Bidichan
import BidichanKit

/// Forwards the Go core's log lines to the shared on-device log.
final class GoLogger: NSObject, MobileLoggerProtocol {
    func log(_ line: String?) {
        guard let line else { return }
        AppLog.log("go: " + line.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// What the Go core reports about the connection underneath a running session.
enum GoLinkState: String {
    /// Traffic is flowing.
    case up
    /// The network is gone and the core is redialing. The session, its channels
    /// and the connections inside them are stalled, not closed — nothing needs
    /// to be rebuilt if the link comes back within the grace period.
    case down
    /// The session could not be resumed and is being rebuilt from scratch.
    case failed
}

/// Bridges the Go core's connection-state callbacks back into Swift.
final class GoLinkObserver: NSObject, MobileLinkObserverProtocol {
    private let onState: (GoLinkState) -> Void
    private let onSession: (Bool) -> Void

    /// - Parameters:
    ///   - onState: called on every link transition.
    ///   - onSession: called when a session is established; the flag is true
    ///     when it replaces one that was lost, meaning channels must be reopened.
    init(onState: @escaping (GoLinkState) -> Void, onSession: @escaping (Bool) -> Void) {
        self.onState = onState
        self.onSession = onSession
    }

    func onLinkState(_ state: String?) {
        guard let state, let parsed = GoLinkState(rawValue: state) else { return }
        onState(parsed)
    }

    func onSessionUp(_ reestablished: Bool) {
        onSession(reestablished)
    }
}

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
    private let logger = GoLogger()
    // gomobile keeps only a weak reference to a Swift-implemented Go interface,
    // so the observer has to be owned here or it is collected mid-session.
    private var observer: GoLinkObserver?

    init() {
        // MobileNewClient wraps a Go pointer and never returns nil in practice.
        client = MobileNewClient()!
        client.setLogger(logger)   // must be before start()
    }

    /// Installs the connection-state sink. Must be called before `start`.
    func observeLink(onState: @escaping (GoLinkState) -> Void,
                     onSession: @escaping (Bool) -> Void) {
        let observer = GoLinkObserver(onState: onState, onSession: onSession)
        self.observer = observer
        client.setLinkObserver(observer)
    }

    /// Tells the core the device's network path changed, so a stalled
    /// connection is redialed at once instead of after a timeout.
    func networkChanged() {
        client.networkChanged()
    }

    /// Points tun channels at a new packet flow. Needed before reopening a tun
    /// channel on a rebuilt session: closing the old channel closed the old flow.
    func setPacketFlow(_ flow: PacketFlowBridge) {
        client.setPacketFlow(flow)
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
               resumeGraceSeconds: Int,
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
        cfg.resumeGraceSeconds = resumeGraceSeconds
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
            try client.awaitDone()
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
