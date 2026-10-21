import SwiftUI

struct SessionsView: View {
    @Environment(Client.self) private var client
    @Environment(\.scenePhase) private var scenePhase
    @State private var sessions: [SessionSummary] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var search = ""
    @State private var selection: String?
    // Show the list next to the session on iPad, also in portrait; iPhone ignores this.
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var showSettings = false
    @State private var showNew = false
    @State private var showUsage = false
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""
    @State private var deleting: SessionSummary?
    @State private var plan: PlanUsage?
    @AppStorage(Prefs.pinnedKey) private var pinnedIDs: [String] = []

    private var filtered: [SessionSummary] {
        guard !search.isEmpty else { return sessions }
        return sessions.filter { s in
            [s.title, s.folder, s.branch].contains { $0?.localizedCaseInsensitiveContains(search) == true }
        }
    }
    private var liveNow: [SessionSummary] {
        filtered.compactMap { s in SessionStatus(state: s.state, mac: s.mac).map { (s, $0.rank) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.updated > $1.0.updated }
            .map(\.0)
    }
    /// Pinned sessions that are not already under "Active now".
    private var pinned: [SessionSummary] {
        pinnedIDs.compactMap { id in filtered.first { $0.id == id } }.filter { SessionStatus(state: $0.state, mac: $0.mac) == nil }
    }
    private var byProject: [(String, [SessionSummary])] {
        let rest = filtered.filter { ($0.state == nil || $0.state == "closed") && !pinnedIDs.contains($0.id) }
        let groups = Dictionary(grouping: rest, by: \.folder)
        return groups.map { ($0.key, $0.value) }.sorted { ($0.1.first?.updated ?? 0) > ($1.1.first?.updated ?? 0) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                // Inside the list, so the banners scroll away instead of covering rows.
                Section {
                    VStack(spacing: 10) {
                        offlineBanner
                        loggedOutBanner
                        if let plan, plan.available, search.isEmpty { PlanMeter(plan: plan).padding(.horizontal, 14).padding(.vertical, 4).card() }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                if !liveNow.isEmpty {
                    Section("Active now") { ForEach(liveNow) { row($0, showFolder: true) } }
                }
                if !pinned.isEmpty {
                    Section("Pinned") { ForEach(pinned) { row($0, showFolder: true) } }
                }
                ForEach(byProject, id: \.0) { project, items in
                    // The project is the section heading; search results mix projects, so they keep it.
                    Section(project) { ForEach(items) { row($0, showFolder: !search.isEmpty) } }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, prompt: "Search sessions")
            .overlay { emptyState }
            .navigationTitle("Tether")
            .refreshable { await load() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gear") { showSettings = true }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Usage", systemImage: "chart.bar") { showUsage = true }
                        .disabled(!client.isConfigured)
                    Button("New session", systemImage: "square.and.pencil") { showNew = true }
                        .disabled(!client.isConfigured)
                }
            }
        } detail: {
            if let id = selection {
                let summary = sessions.first { $0.id == id }
                SessionView(id: id, title: summary?.title, mac: summary?.mac)
                    .id(id)
            } else {
                ContentUnavailableView("Pick a session", systemImage: "terminal", description: Text("Or start a new one with the pencil button."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings, onDismiss: { Task { await load() } }) { SettingsView() }
        .sheet(isPresented: $showUsage) { UsageView() }
        .sheet(isPresented: $showNew) {
            NewSessionView(recentFolders: recentFolders) { id in
                Task {
                    await load()
                    selection = id
                }
            }
        }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                guard let s = renaming else { return }
                Task { await act { try await client.rename(s.id, title: newTitle) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this session?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let s = deleting else { return }
                if selection == s.id { selection = nil }
                Task { await act { try await client.delete(s.id) } }
            }
        } message: {
            Text("Its transcript is removed from your Mac. This can't be undone.")
        }
        .onChange(of: client.isConfigured) {
            Task {
                try? await client.loadInfo()
                await load()
            }
        }
        .onChange(of: client.pendingPairing) {
            if client.pendingPairing != nil { showUsage = false; showNew = false; showSettings = true }
        }
        .onChange(of: client.listVersion) { Task { await load() } }
        .onChange(of: client.openSessionID) {
            if let id = client.openSessionID { selection = id; client.openSessionID = nil }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if !client.isConfigured || client.pendingPairing != nil { showSettings = true }
            try? await client.loadInfo()
            // Keep the list fresh while the app is open; plan limits change slowly, so once a minute.
            var tick = 0
            while !Task.isCancelled {
                await load()
                if tick % 8 == 0 { plan = try? await client.plan() }
                tick += 1
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    private func row(_ s: SessionSummary, showFolder: Bool) -> some View {
        SessionRow(session: s, showFolder: showFolder)
            .tag(s.id)
            .swipeActions(edge: .leading) {
                Button(pinnedIDs.contains(s.id) ? "Unpin" : "Pin", systemImage: pinnedIDs.contains(s.id) ? "pin.slash" : "pin") { pinnedIDs.toggle(s.id) }
                    .tint(.orange)
            }
            .swipeActions(edge: .trailing) {
                if s.state == nil || s.state == "closed" {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = s }
                }
                Button("Rename", systemImage: "pencil") { newTitle = s.title ?? ""; renaming = s }
                    .tint(.indigo)
            }
            .contextMenu {
                Button(pinnedIDs.contains(s.id) ? "Unpin" : "Pin", systemImage: pinnedIDs.contains(s.id) ? "pin.slash" : "pin") { pinnedIDs.toggle(s.id) }
                Button("Rename", systemImage: "pencil") { newTitle = s.title ?? ""; renaming = s }
                if let cwd = s.cwd { Button("Copy folder path", systemImage: "doc.on.doc") { UIPasteboard.general.string = cwd } }
                if s.state == nil || s.state == "closed" {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = s }
                }
            }
    }

    @ViewBuilder private var emptyState: some View {
        if !client.isConfigured {
            ContentUnavailableView {
                Label("Pair with your Mac", systemImage: "qrcode.viewfinder")
            } description: {
                Text("Run **npm run pair** on your Mac and scan the code with the Camera app.")
            } actions: {
                Button("Settings") { showSettings = true }.buttonStyle(.borderedProminent)
            }
        } else if !loaded && error == nil {
            ProgressView()
        } else if sessions.isEmpty && error == nil {
            ContentUnavailableView("No sessions yet", systemImage: "terminal", description: Text("Start one with the pencil button."))
        } else if !search.isEmpty && filtered.isEmpty {
            ContentUnavailableView.search(text: search)
        }
    }

    // Sessions fail with a login error until Claude Code on the Mac is logged in again; say so up front.
    @ViewBuilder private var loggedOutBanner: some View {
        let out = client.info?.accounts?.filter { $0.loggedIn == false } ?? []
        if !out.isEmpty && error == nil {
            Button { showSettings = true } label: {
                HStack(alignment: .top) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(Color.accentColor).font(.title3)
                    Text("Claude Code is logged out on your Mac (\(out.map(\.name).joined(separator: ", "))). On the Mac, run **claude** and type **/login**.")
                        .font(.footnote).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .padding(2)
                .card(tint: .accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var offlineBanner: some View {
        if let error, client.isConfigured {
            HStack {
                Image(systemName: "wifi.exclamationmark")
                Text(error).font(.footnote).lineLimit(2)
                Spacer()
                Button("Retry") { Task { await load() } }.font(.footnote.bold())
            }
            .padding(10)
            .card(tint: .orange)
        }
    }

    private var recentFolders: [String] {
        sessions.compactMap(\.cwd).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private func load() async {
        guard client.isConfigured else { return }
        do {
            sessions = try await client.sessions()
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func act(_ work: () async throws -> Void) async {
        do { try await work() } catch { self.error = error.localizedDescription }
        await load()
    }
}

struct SessionRow: View {
    let session: SessionSummary
    var showFolder = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProjectBadge(name: session.folder).padding(.top, 2)
            details
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title ?? "Untitled").font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Text(session.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let status = SessionStatus(state: session.state, mac: session.mac) { StatusLine(status: status) }
            HStack(spacing: 4) {
                if showFolder { Text(session.folder) }
                if let branch = session.branch, branch != "HEAD" {
                    if showFolder { Text("·") }
                    Image(systemName: "arrow.triangle.branch").imageScale(.small)
                    Text(branch)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// What a session is doing right now, in one line: the list row and the session title use the same words.
struct SessionStatus {
    let label: String
    let color: Color
    let icon: String
    let active: Bool   // animates while Claude is busy or waiting
    let rank: Int      // sort order in "Active now": needs you, then working, then the rest

    init?(state: String?, mac: MacRun?) {
        switch (state, mac) {
        case ("waiting", _): (label, color, icon, active, rank) = ("Needs you", .orange, "hand.raised.fill", true, 0)
        case ("running", _): (label, color, icon, active, rank) = ("Working", .blue, "ellipsis.circle.fill", true, 1)
        case ("idle", _): (label, color, icon, active, rank) = ("Ready for your next message", .green, "checkmark.circle.fill", false, 3)
        case (_, let mac?) where mac.working: (label, color, icon, active, rank) = ("Working in the \(mac.place)", .blue, mac.icon, true, 2)
        case (_, let mac?): (label, color, icon, active, rank) = ("Open in the \(mac.place)", .secondary, mac.icon, false, 4)
        default: return nil
        }
    }
}

struct StatusLine: View {
    let status: SessionStatus

    var body: some View {
        // Not a Label: inside a List, a Label's icon gets a wide fixed column.
        HStack(spacing: 4) {
            Image(systemName: status.icon).imageScale(.small)
            Text(status.label)
        }
        .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .symbolEffect(.pulse, isActive: status.active)
            .lineLimit(1)
    }
}
