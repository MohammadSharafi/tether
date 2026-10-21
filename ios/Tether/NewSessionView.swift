import SwiftUI

struct NewSessionView: View {
    @Environment(Client.self) private var client
    @Environment(\.dismiss) private var dismiss
    let recentFolders: [String]
    let onStart: (String) -> Void
    @AppStorage("lastFolder") private var cwd = ""
    @AppStorage(Prefs.modeKey) private var mode = "default"
    @AppStorage(Prefs.modelKey) private var model = "default"
    @AppStorage(Prefs.effortKey) private var effort = "default"
    @AppStorage(Prefs.favoritesKey) private var favorites: [String] = []
    @State private var prompt = ""
    @State private var attachments: [Attachment] = []
    @State private var error: String?
    @State private var busy = false
    @State private var browsing = false
    @FocusState private var promptFocused: Bool

    private var name: (String) -> String { { URL(fileURLWithPath: $0).lastPathComponent } }
    private var recentsNotFavorite: [String] { recentFolders.filter { !favorites.contains($0) }.prefix(5).map { $0 } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    Button { browsing = true } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cwd.isEmpty ? "Choose a folder on your Mac" : name(cwd)).foregroundStyle(.primary)
                                if !cwd.isEmpty { Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                        }
                    }
                    if !favorites.isEmpty || !recentsNotFavorite.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(favorites, id: \.self) { f in chip(f, icon: "star.fill") }
                                ForEach(recentsNotFavorite, id: \.self) { f in chip(f, icon: "clock") }
                            }
                        }
                    }
                }
                Section("What should Claude do?") {
                    TextField("Describe the task", text: $prompt, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($promptFocused)
                    AttachmentPicker(attachments: $attachments)
                }
                Section {
                    Picker("Permissions", selection: $mode) {
                        ForEach(client.info?.modes ?? ["default"], id: \.self) { m in
                            Label(Mode.label(m), systemImage: Mode.icon(m)).tag(m)
                        }
                    }
                    Picker("Model", selection: $model) {
                        ForEach(client.info?.models ?? [], id: \.value) { m in Text(m.displayName).tag(m.value) }
                    }
                    Picker("Effort", selection: $effort) {
                        ForEach(client.info?.efforts ?? Effort.all, id: \.self) { e in Text(Effort.label(e)).tag(e) }
                    }
                } footer: {
                    Text("\(Effort.detail(effort)). Anything your Mac's settings don't already allow comes to this phone for approval.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $browsing) {
                FolderBrowser(start: cwd.isEmpty ? nil : cwd) { picked in cwd = picked; browsing = false }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Start") { start() }
                            .disabled(cwd.isEmpty || (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                    }
                }
            }
            .onAppear {
                if cwd.isEmpty { cwd = favorites.first ?? recentFolders.first ?? "" }
                promptFocused = true
            }
        }
    }

    private func chip(_ folder: String, icon: String) -> some View {
        Button { cwd = folder } label: {
            Label(name(folder), systemImage: icon)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(cwd == folder ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func start() {
        busy = true
        Task {
            do {
                let id = try await client.start(cwd: cwd, prompt: prompt, images: attachments, mode: mode, model: model, effort: effort)
                dismiss()
                onStart(id)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Browse the Mac's folders (inside your home folder) and pick one. Star a folder to keep it as a favorite.
struct FolderBrowser: View {
    @Environment(Client.self) private var client
    let start: String?
    let pick: (String) -> Void
    @State private var path: String?
    @State private var listing: FolderListing?
    @State private var error: String?
    @State private var filter = ""
    @AppStorage(Prefs.favoritesKey) private var favorites: [String] = []

    private var shown: [FolderListing.Folder] {
        guard let listing else { return [] }
        return filter.isEmpty ? listing.dirs : listing.dirs.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        List {
            if let listing {
                Section {
                    Button { pick(listing.path) } label: {
                        Label("Use “\(URL(fileURLWithPath: listing.path).lastPathComponent)”", systemImage: "checkmark.circle.fill")
                            .font(.body.bold())
                    }
                    if let parent = listing.parent {
                        Button { path = parent } label: { Label("Up to \(URL(fileURLWithPath: parent).lastPathComponent)", systemImage: "arrow.turn.left.up") }
                    }
                } footer: {
                    Text(listing.path).lineLimit(2)
                }
                Section {
                    ForEach(shown) { f in
                        HStack {
                            Button { path = f.path } label: {
                                Label {
                                    Text(f.name).foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: f.repo ? "folder.badge.gearshape" : "folder").foregroundStyle(.blue)
                                }
                            }
                            Spacer()
                            Button(favorites.contains(f.path) ? "Remove favorite" : "Add favorite",
                                   systemImage: favorites.contains(f.path) ? "star.fill" : "star") { favorites.toggle(f.path) }
                                .labelStyle(.iconOnly)
                                .foregroundStyle(favorites.contains(f.path) ? .yellow : .secondary)
                                .buttonStyle(.borderless)
                        }
                        .swipeActions { Button("Use", systemImage: "checkmark") { pick(f.path) }.tint(.blue) }
                    }
                } footer: {
                    if listing.dirs.isEmpty { Text("No folders here.") }
                    else { Text("Git projects have a gear on their folder. Swipe left to use a folder directly.") }
                }
            } else if let error {
                ContentUnavailableView("Can't open this folder", systemImage: "folder.badge.questionmark", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .searchable(text: $filter, prompt: "Filter folders")
        .navigationTitle(listing.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Folders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let listing {
                Button(favorites.contains(listing.path) ? "Remove favorite" : "Add favorite",
                       systemImage: favorites.contains(listing.path) ? "star.fill" : "star") { favorites.toggle(listing.path) }
            }
        }
        .task(id: path) {
            do {
                listing = try await client.folders(path ?? start)
                error = nil
            } catch is CancellationError {
            } catch {
                // A remembered folder may be gone: fall back to the home folder once.
                if path == nil && start != nil, let home = try? await client.folders(nil) { listing = home }
                else { self.error = error.localizedDescription }
            }
            filter = ""
        }
    }
}
