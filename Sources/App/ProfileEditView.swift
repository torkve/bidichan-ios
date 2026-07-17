import SwiftUI
import BidichanKit

struct ProfileEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var profile: Profile
    @State private var psk: String = ""

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

            Section("System VPN (TUN)") {
                Toggle("Enable VPN tunnel", isOn: $profile.enableTUN)
                TextField("Device CIDR (e.g. 10.42.0.2/24)", text: $profile.tunCIDR)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper("MTU: \(profile.tunMTU)", value: $profile.tunMTU, in: 1000...1500, step: 20)
                Toggle("Route all traffic (full tunnel)", isOn: $profile.fullTunnel)
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
