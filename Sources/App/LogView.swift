import SwiftUI
import BidichanKit

/// Shows the shared on-device log (app + tunnel extension) so connection
/// problems can be diagnosed without a Mac. Refresh / share / clear.
struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    /// Written when the log is read, not when the toolbar draws: building it in
    /// the view body would put a file write on every redraw.
    @State private var exported: URL?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "No logs yet." : text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Color.clear.frame(height: 1).id("bottom")
            }
            .onAppear {
                reload()
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                // The file, not the text: a log this long pasted into a chat
                // app is truncated, and what comes back is a screenshot of it.
                if let exported {
                    ShareLink(item: exported, preview: SharePreview("bidichan log")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    AppLog.clear()
                    text = ""
                    exported = nil
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    private func reload() {
        text = AppLog.read()
        exported = AppLog.exportURL()
    }
}
