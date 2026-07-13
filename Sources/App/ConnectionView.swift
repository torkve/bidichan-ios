import SwiftUI
import NetworkExtension
import BidichanKit

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile

    @State private var showForward = false
    @State private var forwardListen = "127.0.0.1:8080"
    @State private var forwardTarget = "internal-host:80"

    private var isActiveProfile: Bool { model.tunnel.activeProfileID == profile.id.uuidString }
    private var connected: Bool { isActiveProfile && model.status == .connected }
    private var channels: [ChannelSnapshot] { model.peers.flatMap { $0.channels ?? [] } }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(connected ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)
                    Text(isActiveProfile ? model.statusText : "Disconnected")
                    Spacer()
                    if isActiveProfile && model.isBusy { ProgressView() }
                }
                if connected {
                    Button(role: .destructive) {
                        model.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        Task { await model.connect(profile) }
                    } label: {
                        Label("Connect", systemImage: "play.circle")
                    }
                    .disabled(model.isBusy)
                }
            }

            if connected {
                Section("Channels") {
                    if channels.isEmpty {
                        Text("No open channels").foregroundStyle(.secondary)
                    }
                    ForEach(channels) { ch in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(ch.kind) · #\(ch.id)").font(.headline)
                            Text(ch.description).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Close", role: .destructive) {
                                Task { await model.closeChannel(ch.id) }
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        ShellView()
                    } label: {
                        Label("Interactive shell", systemImage: "terminal")
                    }
                }
            }
        }
        .navigationTitle(profile.name)
        .toolbar {
            if connected {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("SOCKS5 proxy (:1080)") {
                            Task { await model.openSocks5(listen: "127.0.0.1:1080") }
                        }
                        Button("HTTP proxy (:3128)") {
                            Task { await model.openHTTP(listen: "127.0.0.1:3128") }
                        }
                        Button("Port forward…") { showForward = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showForward) {
            NavigationStack {
                Form {
                    Section("Local forward (-L)") {
                        TextField("Listen (host:port)", text: $forwardListen)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Target (host:port)", text: $forwardTarget)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                .navigationTitle("Port forward")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showForward = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Open") {
                            let listen = forwardListen, target = forwardTarget
                            showForward = false
                            Task { await model.openForward(listen: listen, target: target) }
                        }
                    }
                }
            }
        }
        .task(id: connected) {
            if connected { await model.refreshStatus() }
        }
    }
}
