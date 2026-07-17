import SwiftUI
import BidichanKit

struct ProfileEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var profile: Profile
    @State private var psk: String = ""
    @State private var editingChannel: ChannelConfig?

    init(profile: Profile) {
        _profile = State(initialValue: profile)
    }

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $profile.name)
                    .textContentType(.name)
                TextField("Server (host:port)", text: $profile.serverAddress)
                    .textContentType(.URL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Hostname / SNI", text: $profile.hostname)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                // Explicit .URL content type keeps iOS AutoFill from mis-flagging
                // this field as a password (which blocks third-party keyboards).
                TextField("WebSocket path (e.g. /ws)", text: $profile.path)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }

            Section("Authentication") {
                SecureField("Pre-shared key (hex)", text: $psk)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Server behind TLS proxy", isOn: $profile.noTLSBinding)
                Picker("TLS fingerprint", selection: $profile.fingerprint) {
                    Text("iOS (Safari)").tag("ios")
                    Text("Safari (macOS)").tag("safari")
                    Text("Chrome").tag("chrome")
                }
            }

            Section("System tunnel (TUN)") {
                Toggle("Enable tunnel", isOn: $profile.enableTUN)
                TextField("Device IPv4 (e.g. 10.42.0.2/24)", text: $profile.tunCIDR)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Device IPv6 (optional, e.g. fd00:bd::2/64)", text: $profile.tunCIDR6)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper("MTU: \(profile.tunMTU)", value: $profile.tunMTU, in: 1000...1500, step: 20)
                Toggle("Route all traffic (full tunnel)", isOn: $profile.fullTunnel)
            }

            Section {
                ForEach(profile.channels) { c in
                    Button {
                        editingChannel = c
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.displayName).foregroundStyle(.primary)
                            Text("\(c.kind.title) · \(c.listenAddr)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { profile.channels.remove(atOffsets: $0) }

                Button {
                    editingChannel = ChannelConfig()
                } label: {
                    Label("Add default channel", systemImage: "plus")
                }
            } header: {
                Text("Default channels")
            } footer: {
                Text("Opened automatically after this profile connects.")
            }

            Section("Advanced") {
                Stepper("NE memory limit: \(profile.memoryLimitMB) MB",
                        value: $profile.memoryLimitMB, in: 20...80, step: 5)
                TextField("CA certificate PEM (optional)", text: $profile.caCertPEM, axis: .vertical)
                    .lineLimit(3...8).font(.caption.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
        .navigationTitle(profile.name.isEmpty ? "Profile" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(profile.serverAddress.isEmpty || profile.hostname.isEmpty)
            }
        }
        .onAppear { psk = model.store.psk(for: profile) ?? "" }
        .sheet(item: $editingChannel) { channel in
            ChannelConfigEditView(config: channel) { edited in
                if let idx = profile.channels.firstIndex(where: { $0.id == edited.id }) {
                    profile.channels[idx] = edited
                } else {
                    profile.channels.append(edited)
                }
            }
        }
    }

    private func save() {
        model.store.upsert(profile)
        let trimmed = psk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try? model.store.setPSK(trimmed, for: profile)
        }
        dismiss()
    }
}

/// Sheet that edits one default `ChannelConfig` and hands the result back.
struct ChannelConfigEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config: ChannelConfig
    let onSave: (ChannelConfig) -> Void

    init(config: ChannelConfig, onSave: @escaping (ChannelConfig) -> Void) {
        _config = State(initialValue: config)
        self.onSave = onSave
    }

    private var portValid: Bool { config.port > 0 && config.port <= 65535 }

    var body: some View {
        NavigationStack {
            Form { ChannelConfigFields(config: $config) }
                .navigationTitle("Default channel")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onSave(config); dismiss() }.disabled(!portValid)
                    }
                }
        }
    }
}
