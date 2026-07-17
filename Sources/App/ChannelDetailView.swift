import SwiftUI
import UIKit
import BidichanKit

/// Detail + actions for one open channel: the bound address, "Open in Safari" /
/// "Copy" for forwards, the system-routing toggle for proxies, and close.
struct ChannelDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: ChannelSnapshot

    private var isProxy: Bool { channel.kind == "http" || channel.kind == "socks5" }
    private var isForward: Bool { channel.kind == "forward" }
    private var bound: String? { Self.boundAddr(from: channel.description) }
    private var port: Int? { bound.flatMap { $0.split(separator: ":").last.flatMap { Int($0) } } }

    private var isActiveSystemProxy: Bool {
        guard let sp = model.systemProxy, let port else { return false }
        return sp.port == port && sp.kind == (channel.kind == "http" ? "http" : "socks5")
    }

    var body: some View {
        Form {
            Section("Channel") {
                if let l = channel.label, !l.isEmpty {
                    LabeledContent("Label", value: l)
                }
                LabeledContent("Kind", value: channel.kind)
                LabeledContent("ID", value: "#\(channel.id)")
                if let bound { LabeledContent("Bound", value: bound) }
                Text(channel.description).font(.caption).foregroundStyle(.secondary)
            }

            if isForward, let bound, let url = Self.safariURL(bound) {
                Section("Use") {
                    Link(destination: url) { Label("Open in Safari", systemImage: "safari") }
                    Button {
                        UIPasteboard.general.string = bound
                    } label: {
                        Label("Copy \(bound)", systemImage: "doc.on.doc")
                    }
                }
            }

            if isProxy, let port {
                Section {
                    Toggle("Route system apps through this proxy", isOn: Binding(
                        get: { isActiveSystemProxy },
                        set: { on in
                            let kind = channel.kind == "http" ? "http" : "socks5"
                            Task {
                                if on { await model.setSystemProxy(kind: kind, host: "127.0.0.1", port: port) }
                                else { await model.clearSystemProxy() }
                            }
                        }))
                } footer: {
                    if model.systemProxy != nil && !isActiveSystemProxy {
                        Text("Another proxy is currently the system proxy; enabling this replaces it.")
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    let id = channel.id
                    if isActiveSystemProxy { Task { await model.clearSystemProxy() } }
                    dismiss()
                    Task { await model.closeChannel(id) }
                } label: {
                    Label("Close channel", systemImage: "xmark.circle")
                }
            }
        }
        .navigationTitle("\(channel.kind) #\(channel.id)")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Pulls the bound address out of the Go channel description, which reads
    /// e.g. "socks5 proxy on 127.0.0.1:1080 -> …" or "forward listen=127.0.0.1:8080 -> …".
    static func boundAddr(from desc: String) -> String? {
        for marker in ["listen=", " on "] {
            if let r = desc.range(of: marker) {
                let addr = desc[r.upperBound...].prefix { $0 != " " }
                if addr.contains(":") { return String(addr) }
            }
        }
        return nil
    }

    static func safariURL(_ bound: String) -> URL? {
        let parts = bound.split(separator: ":")
        guard parts.count == 2 else { return nil }
        let host = parts[0] == "0.0.0.0" ? "127.0.0.1" : String(parts[0])
        return URL(string: "http://\(host):\(parts[1])")
    }
}
