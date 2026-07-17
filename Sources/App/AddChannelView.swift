import SwiftUI
import BidichanKit

/// Configurable creation of a proxy or port-forward channel (kind, interface,
/// port, target, an optional label, and — for proxies — whether to route system
/// apps through it). Reuses `ChannelConfig` so it matches the profile's default
/// channels exactly.
struct AddChannelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var config = ChannelConfig()

    private var portValid: Bool { config.port > 0 && config.port <= 65535 }

    var body: some View {
        Form {
            ChannelConfigFields(config: $config)
        }
        .navigationTitle("Add channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Open") { open() }.disabled(!portValid)
            }
        }
    }

    private func open() {
        guard portValid else { return }
        let c = config
        dismiss()
        Task {
            let label = c.label.isEmpty ? nil : c.label
            if c.kind.isProxy {
                await model.openProxy(c.kind == .http ? .http : .socks5,
                                      side: .local, listen: c.listenAddr, label: label)
                if c.routeSystem {
                    // The system reaches the proxy over loopback regardless of the
                    // bind interface.
                    await model.setSystemProxy(kind: c.kind.proxyKind, host: "127.0.0.1", port: c.port)
                }
            } else {
                await model.openForward(side: c.kind.side, listen: c.listenAddr,
                                        target: c.target, label: label)
            }
        }
    }
}

/// The shared editor body for a `ChannelConfig`, used both by the ad-hoc
/// "Add channel" sheet and the per-profile default-channel editor.
struct ChannelConfigFields: View {
    @Binding var config: ChannelConfig

    private var portText: Binding<String> {
        Binding(get: { String(config.port) },
                set: { config.port = Int($0.filter(\.isNumber)) ?? 0 })
    }

    var body: some View {
        Section("Channel") {
            Picker("Kind", selection: $config.kind) {
                ForEach(ChannelConfig.Kind.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: config.kind) { _, new in config.port = new.defaultPort }
            TextField("Label (optional)", text: $config.label)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }

        Section(config.kind.side == .remote ? "Listen on the peer" : "Listen on this device") {
            Picker("Interface", selection: $config.allInterfaces) {
                Text("Loopback (127.0.0.1)").tag(false)
                Text("All interfaces (0.0.0.0)").tag(true)
            }
            TextField("Port", text: portText).keyboardType(.numberPad)
        }

        if config.kind.isForward {
            Section("Target (reached via the peer)") {
                TextField("host:port", text: $config.target)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }

        if config.kind.isProxy {
            Section {
                Toggle("Route system apps through this proxy", isOn: $config.routeSystem)
            } footer: {
                Text(config.kind == .http
                     ? "Publishes the proxy to iOS so apps route HTTP/HTTPS through the peer, alongside the tunnel."
                     : "Published via a PAC; honored by apps that support PAC. An HTTP proxy is more widely honored for system routing.")
            }
        }

        if config.allInterfaces {
            Section {
                Text("Binding all interfaces exposes this on your local network to other devices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
