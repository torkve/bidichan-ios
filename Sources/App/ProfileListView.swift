import SwiftUI
import BidichanKit

struct ProfileListView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Profile?

    var body: some View {
        List {
            if model.store.profiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "network").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No profiles").font(.headline)
                    Text("Tap + to add a bidichan server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
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
                .swipeActions {
                    Button("Edit") { editing = profile }.tint(.blue)
                }
            }
            .onDelete { offsets in
                offsets.map { model.store.profiles[$0] }.forEach(model.store.delete)
            }
        }
        .navigationTitle("bidichan")
        .navigationDestination(for: Profile.self) { ConnectionView(profile: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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
    }
}
