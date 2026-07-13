import SwiftUI

@main
struct BidichanApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ProfileListView()
            }
            .environmentObject(model)
            .task { await model.onAppear() }
            .alert("Error",
                   isPresented: Binding(get: { model.errorMessage != nil },
                                        set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }
}
