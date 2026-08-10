import SwiftUI

@main
struct BidichanApp: App {
    @StateObject private var model = AppModel()

    /// A profile that arrived as a link, waiting to be confirmed. Nothing is
    /// saved until the user accepts it.
    @State private var incoming: IncomingProfile?

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ProfileListView()
            }
            .environmentObject(model)
            .task { await model.onAppear() }
            .onOpenURL { url in open(url) }
            .sheet(item: $incoming) { pending in
                NavigationStack {
                    ImportProfileView(incoming: pending.value)
                        .environmentObject(model)
                }
            }
            .alert("Error",
                   isPresented: Binding(get: { model.errorMessage != nil },
                                        set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private func open(_ url: URL) {
        guard ProfileLinking.isProfileLink(url) else { return }
        do {
            incoming = IncomingProfile(value: try ProfileLinking.decode(url))
        } catch {
            // The core writes these to be read by a person.
            model.errorMessage = error.localizedDescription
        }
    }
}

/// Wraps the decoded link so it can drive an `item:` sheet.
private struct IncomingProfile: Identifiable {
    let id = UUID()
    let value: ProfileLinking.LinkImport
}
