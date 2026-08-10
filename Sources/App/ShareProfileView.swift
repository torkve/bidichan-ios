import SwiftUI
import BidichanKit

/// Hands a profile to another device as a link. The one real decision is
/// whether the pre-shared key travels with it, so that is what the screen is
/// mostly about.
struct ShareProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profile: Profile

    @State private var includeKey = false
    @State private var link: String = ""
    @State private var failure: String?
    /// Built alongside the link rather than in `body`, which would re-encode
    /// the whole thing on every redraw.
    @State private var code: UIImage?
    @State private var sharing = false

    private var hasKey: Bool { !(model.store.psk(for: profile) ?? "").isEmpty }

    var body: some View {
        Form {
            Section {
                Toggle("Include the pre-shared key", isOn: $includeKey)
                    .disabled(!hasKey)
            } header: {
                Text("Key")
            } footer: {
                if !hasKey {
                    Text("This profile has no key saved, so the other device will need it entered "
                         + "separately.")
                } else if includeKey {
                    Text("Anyone who gets this link can use the tunnel. Nothing in the link is "
                         + "encrypted — send it the way you would send the key itself, and delete "
                         + "it afterwards.")
                } else {
                    Text("The link carries the settings only. The other device will ask for the "
                         + "key, which you can send separately.")
                }
            }

            if let failure {
                Section { Text(failure).foregroundStyle(.red) }
            } else if !link.isEmpty {
                Section {
                    Button {
                        sharing = true
                    } label: {
                        Label(code == nil ? "Share link" : "Share code and link",
                              systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = link
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("Send")
                } footer: {
                    Text(code == nil
                         ? "Most chat apps will not make this tappable, because the app registers "
                         + "its own link scheme rather than a web address. The other device can "
                         + "copy the text and use Import from a link."
                         : "Sends both. An app that takes images gets the code with the link "
                         + "alongside it; one that only takes text gets the link. Most chat apps "
                         + "will not make that text tappable — the other device can copy it and "
                         + "use Import from a link, or just scan the code.")
                }

                Section {
                    if let code {
                        // The image carries its own white field and quiet zone,
                        // so it stays scannable wherever it ends up — including
                        // in someone else's chat app.
                        Image(uiImage: code)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Scannable code for this profile")
                    } else {
                        Text("This profile is too large to show as a code — its certificate "
                             + "takes more room than one can hold. Send the link as text instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Scan")
                } footer: {
                    Text(link).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Share \(profile.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear(perform: rebuild)
        .onChange(of: includeKey) { _, _ in rebuild() }
        .sheet(isPresented: $sharing) {
            // The code first, so an app that takes both treats it as the
            // attachment and the link as the text going with it.
            ShareSheet(items: code.map { [$0, link] as [Any] } ?? [link])
        }
    }

    private func rebuild() {
        do {
            link = try ProfileLinking.link(for: profile,
                                           includeKey: includeKey,
                                           psk: model.store.psk(for: profile))
            code = QRCode.image(for: link)
            failure = nil
        } catch {
            link = ""
            code = nil
            failure = error.localizedDescription
        }
    }
}

/// Confirms a profile that arrived as a link before it is saved. An incoming
/// link is someone else's configuration; it is shown in full first.
struct ImportProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let incoming: ProfileLinking.LinkImport

    var body: some View {
        Form {
            Section("Profile") {
                LabeledContent("Name", value: incoming.profile.name)
                LabeledContent("Server", value: incoming.profile.serverAddress)
                LabeledContent("Hostname", value: incoming.profile.hostname)
                if !incoming.profile.path.isEmpty {
                    LabeledContent("Path", value: incoming.profile.path)
                }
            }

            if !incoming.profile.channels.isEmpty {
                Section("Default channels") {
                    ForEach(incoming.profile.channels) { c in
                        LabeledContent(c.displayName, value: c.kind.title)
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                if incoming.carriesKey {
                    Text("This link includes the pre-shared key, so the profile is ready to "
                         + "connect. Delete the link from wherever you received it.")
                } else {
                    Text("This link carries settings only. Add the pre-shared key before "
                         + "connecting.")
                }
            }
        }
        .navigationTitle("Import profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }
            }
        }
    }

    private func add() {
        model.store.upsert(incoming.profile)
        if let psk = incoming.psk, !psk.isEmpty {
            try? model.store.setPSK(psk, for: incoming.profile)
        }
        dismiss()
    }
}
