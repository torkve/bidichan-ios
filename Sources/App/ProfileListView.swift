import SwiftUI
import BidichanKit

struct ProfileListView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Profile?
    @State private var showLogs = false
    @State private var sharing: Profile?
    @State private var importingLink = false

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
                    Button("Share") { sharing = profile }.tint(.indigo)
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
                // A menu rather than a second button: importing a link is not
                // something anyone does often, and it does not deserve equal
                // standing in a toolbar with room for two.
                Menu {
                    Button {
                        editing = Profile()
                    } label: {
                        Label("New profile", systemImage: "plus")
                    }
                    Button {
                        importingLink = true
                    } label: {
                        Label("Import from a link", systemImage: "link")
                    }
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
        .sheet(item: $sharing) { profile in
            NavigationStack {
                ShareProfileView(profile: profile)
            }
        }
        .sheet(isPresented: $importingLink) {
            NavigationStack {
                ImportLinkView()
            }
        }
    }
}
