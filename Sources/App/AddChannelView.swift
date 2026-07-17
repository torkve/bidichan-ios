import SwiftUI
import BidichanKit

/// Configurable creation of a proxy or port-forward channel (kind, interface,
/// port, target, and — for proxies — whether to route system apps through it).
struct AddChannelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Choice: String, CaseIterable, Identifiable {
        case socks5 = "SOCKS5 proxy"
        case http = "HTTP proxy"
        case forwardLocal = "Port forward (-L)"
        case forwardRemote = "Port forward (-R)"
        var id: String { rawValue }
        var isProxy: Bool { self == .socks5 || self == .http }
        var isForward: Bool { !isProxy }
        var side: Side { self == .forwardRemote ? .remote : .local }
        var proxyKind: String { self == .http ? "http" : "socks5" }
        var defaultPort: String {
            switch self {
            case .socks5: return "1080"
            case .http: return "3128"
            case .forwardLocal, .forwardRemote: return "8080"
            }
        }
    }

    @State private var choice: Choice = .http
    @State private var allInterfaces = false
    @State private var port = "3128"
    @State private var target = "127.0.0.1:80"
    @State private var routeSystem = true

    private var host: String { allInterfaces ? "0.0.0.0" : "127.0.0.1" }
    private var portValue: Int? { Int(port.trimmingCharacters(in: .whitespaces)) }
    private var listenAddr: String { "\(host):\(port.trimmingCharacters(in: .whitespaces))" }

    var body: some View {
        Form {
            Section("Channel") {
                Picker("Kind", selection: $choice) {
                    ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: choice) { _, new in port = new.defaultPort }
            }

            Section(choice.side == .remote ? "Listen on the peer" : "Listen on this device") {
                Picker("Interface", selection: $allInterfaces) {
                    Text("Loopback (127.0.0.1)").tag(false)
                    Text("All interfaces (0.0.0.0)").tag(true)
                }
                TextField("Port", text: $port).keyboardType(.numberPad)
            }

            if choice.isForward {
                Section("Target (reached via the peer)") {
                    TextField("host:port", text: $target)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }

            if choice.isProxy {
                Section {
                    Toggle("Route system apps through this proxy", isOn: $routeSystem)
                } footer: {
                    Text(choice == .http
                         ? "Publishes the proxy to iOS so apps route HTTP/HTTPS through the peer, alongside the tunnel."
                         : "Published via a PAC; honored by apps that support PAC. An HTTP proxy is more widely honored for system routing.")
                }
            }

            if allInterfaces {
                Section {
                    Text("Binding all interfaces exposes this on your local network to other devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Add channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Open") { open() }.disabled(portValue == nil)
            }
        }
    }

    private func open() {
        guard let p = portValue else { return }
        let c = choice, listen = listenAddr, route = routeSystem, tgt = target
        dismiss()
        Task {
            if c.isProxy {
                await model.openProxy(c == .http ? .http : .socks5, side: .local, listen: listen)
                if route {
                    // The system reaches the proxy over loopback regardless of the
                    // bind interface.
                    await model.setSystemProxy(kind: c.proxyKind, host: "127.0.0.1", port: p)
                }
            } else {
                await model.openForward(side: c.side, listen: listen, target: tgt)
            }
        }
    }
}
