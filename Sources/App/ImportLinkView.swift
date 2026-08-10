import SwiftUI

/// Imports a profile from a link that arrived as plain text.
///
/// Tapping a link only works where the sender's app made it tappable, and most
/// chat apps only do that for web addresses — never for an app's own scheme. So
/// the text has to be importable by hand as well, or a profile shared over the
/// wrong app cannot be received at all.
struct ImportLinkView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var decoded: ProfileLinking.LinkImport?
    @State private var failure: String?

    var body: some View {
        // Once the link is read, this becomes the same confirmation screen a
        // tapped link would have reached. Swapped rather than pushed, so
        // Cancel and Add close the sheet instead of coming back here.
        if let decoded {
            ImportProfileView(incoming: decoded)
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("bidichan://profile#…", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                // PasteButton rather than reading the pasteboard ourselves:
                // reading it directly makes the system ask the user to approve
                // it, and being asked that on entering a screen reads as the
                // app helping itself to the clipboard.
                PasteButton(payloadType: String.self) { items in
                    guard let first = items.first else { return }
                    text = first.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .labelStyle(.titleAndIcon)
            } header: {
                Text("Link")
            } footer: {
                Text("Paste the link you were sent. It is not saved as a profile until you have "
                     + "seen what is in it.")
            }

            if let failure {
                Section { Text(failure).foregroundStyle(.red) }
            }

            Section {
                Button("Read link", action: read)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Import from a link")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }

    private func read() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ProfileLinking.isProfileLink(url) else {
            failure = "That does not look like a profile link. It should begin with "
                + "\(ProfileLinking.prefix)."
            return
        }
        do {
            // The core writes its errors to be read by a person, so they are
            // shown as they are.
            decoded = try ProfileLinking.decode(url)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
