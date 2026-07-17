import SwiftUI
import BidichanKit

/// Shows the shared on-device log (app + tunnel extension) so connection
/// problems can be diagnosed without a Mac. Refresh / share / clear.
struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

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
                if !text.isEmpty {
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                }
                Button(role: .destructive) {
                    AppLog.clear()
                    text = ""
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    private func reload() { text = AppLog.read() }
}
