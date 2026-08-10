import SwiftUI
import UIKit

/// The system share sheet, carrying more than one kind of item.
///
/// SwiftUI's `ShareLink` shares a single item, and a profile is best sent as
/// two: the scannable code, and the link as text. An app that takes images gets
/// both — Telegram attaches the code and uses the link as its caption — and one
/// that only takes text still gets something it can use. Which is why this
/// drops to `UIActivityViewController`, which accepts a mixed list.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
