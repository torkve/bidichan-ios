import SwiftUI
import BidichanKit

struct ProfileListView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Profile?
    @State private var showLogs = false

    var body: some View {
        List {
            if model.store.profiles.isEmpty {
                ContentUnavailableView("No profiles",
                                       systemImage: "network",
                                       description: Text("Tap + to add a bidichan server."))
                    .listRowBackground(Color.clear)
            }
            ForEach(model.store.profiles) { profile in
                NavigationLink(value: profile) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).font(.headline)
                        Text(profile.serverAddress.isEmpty ? "no address" : profile.serverAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button("Edit") { editing = profile }.tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { model.store.delete(profile) }
                }
            }
            .onDelete { offsets in
                offsets.map { model.store.profiles[$0] }.forEach(model.store.delete)
            }
        }
        .navigationTitle("bidichan")
        .navigationDestination(for: Profile.self) { ConnectionView(profile: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showLogs = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                Button {
                    editing = Profile()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editing) { profile in
            NavigationStack {
                ProfileEditView(profile: profile)
            }
        }
        .sheet(isPresented: $showLogs) {
            NavigationStack {
                LogView()
            }
        }
    }
}
