import SwiftUI
import NetworkExtension
import BidichanKit

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile

    @State private var showAddChannel = false

    private var isActiveProfile: Bool { model.tunnel.activeProfileID == profile.id.uuidString }
    private var connected: Bool { isActiveProfile && model.status == .connected }
    /// Connected, or reconnecting underneath with the channels still open — the
    /// UI should look the same either way, only the status line differs.
    private var live: Bool { isActiveProfile && model.isLive }
    private var channels: [ChannelSnapshot] { model.peers.flatMap { $0.channels ?? [] } }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(connected ? Color.green : (live ? Color.orange : Color.secondary))
                        .frame(width: 10, height: 10)
                    Text(isActiveProfile ? model.statusText : "Disconnected")
                    Spacer()
                    if isActiveProfile && model.isBusy { ProgressView() }
                }
                if live {
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

            if live {
                Section("Channels") {
                    if let sp = model.systemProxy {
                        HStack(spacing: 8) {
                            Image(systemName: "globe").foregroundStyle(.green)
                            Text("System proxy: \(sp.kind) 127.0.0.1:\(sp.port.plain)")
                                .font(.caption)
                            Spacer()
                            Button("Stop") { Task { await model.clearSystemProxy() } }
                                .font(.caption)
                        }
                    }
                    if channels.isEmpty {
                        Text("No open channels").foregroundStyle(.secondary)
                    }
                    ForEach(channels) { ch in
                        NavigationLink(value: ch) {
                            VStack(alignment: .leading, spacing: 2) {
                                if let l = ch.label, !l.isEmpty {
                                    Text(l).font(.headline)
                                    Text("\(ch.kind) · #\(ch.id.plain)").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("\(ch.kind) · #\(ch.id.plain)").font(.headline)
                                }
                                Text(ch.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Close", role: .destructive) {
                                Task { await model.closeChannel(ch.id) }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showAddChannel = true
                    } label: {
                        Label("Add channel", systemImage: "plus.circle")
                    }
                    NavigationLink {
                        ShellView()
                    } label: {
                        Label("Interactive shell", systemImage: "terminal")
                    }
                }
            }
        }
        .navigationTitle(profile.name)
        .navigationDestination(for: ChannelSnapshot.self) { ChannelDetailView(channel: $0) }
        .sheet(isPresented: $showAddChannel) {
            NavigationStack { AddChannelView() }
        }
        .task(id: live) {
            if live { await model.refreshStatus() }
        }
    }
}
