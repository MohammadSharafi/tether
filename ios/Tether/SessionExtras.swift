import SwiftUI
import ActivityKit

// MARK: - Quick replies

/// One-tap replies above the message box. Edit the list in Settings, or with the last chip.
struct QuickReplyBar: View {
    let send: (String) -> Void
    @AppStorage(Prefs.quickRepliesKey) private var replies: [String] = Prefs.defaultQuickReplies
    @State private var editing = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(replies, id: \.self) { r in
                    Button(r) { send(r) }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .buttonStyle(.plain)
                }
                Button("Edit quick replies", systemImage: "slider.horizontal.3") { editing = true }
                    .labelStyle(.iconOnly)
                    .font(.footnote)
                    .padding(6)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $editing) { NavigationStack { QuickRepliesEditor() } }
    }
}

struct QuickRepliesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.quickRepliesKey) private var replies: [String] = Prefs.defaultQuickReplies
    @State private var newReply = ""

    var body: some View {
        List {
            Section {
                ForEach(replies, id: \.self) { Text($0) }
                    .onDelete { replies.remove(atOffsets: $0) }
                    .onMove { replies.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("Tap a quick reply in a session to send it. Swipe to delete, drag to reorder.")
            }
            Section("Add") {
                HStack {
                    TextField("e.g. Fix the failing test", text: $newReply).onSubmit(add)
                    Button("Add", action: add).disabled(newReply.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                Button("Restore the suggestions") { replies = Prefs.defaultQuickReplies }
            }
        }
        .navigationTitle("Quick replies")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        .toolbar { Button("Done") { dismiss() } }
    }

    private func add() {
        let r = newReply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.isEmpty && !replies.contains(r) { replies.append(r) }
        newReply = ""
    }
}

// MARK: - Slash commands

/// Matches for the "/word" being typed, shown right above the message box.
struct CommandSuggestions: View {
    let commands: [SlashCommand]
    let query: String
    let pick: (SlashCommand) -> Void

    var body: some View {
        let typed = query.dropFirst().lowercased()
        let matches = commands.filter { typed.isEmpty || $0.name.lowercased().hasPrefix(typed) }.prefix(6)
        if !matches.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(matches)) { c in
                    Button { pick(c) } label: { CommandRow(command: c) }
                        .buttonStyle(.plain)
                    if c != matches.last { Divider() }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct CommandRow: View {
    let command: SlashCommand

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("/\(command.name)").font(.callout.monospaced().bold())
            if let hint = command.argumentHint { Text(hint).font(.caption.monospaced()).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Text(command.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct CommandsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let commands: [SlashCommand]?
    let error: String?
    let pick: (SlashCommand) -> Void
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Group {
                if let commands {
                    let shown = search.isEmpty ? commands : commands.filter { "\($0.name) \($0.description)".localizedCaseInsensitiveContains(search) }
                    List {
                        let builtin = shown.filter(\.builtin), custom = shown.filter { !$0.builtin }
                        if !custom.isEmpty { Section("Your commands and skills") { rows(custom) } }
                        if !builtin.isEmpty { Section("Claude Code") { rows(builtin) } }
                    }
                    .searchable(text: $search, prompt: "Search commands")
                } else if let error {
                    ContentUnavailableView("Couldn't load commands", systemImage: "slash.circle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func rows(_ list: [SlashCommand]) -> some View {
        ForEach(list) { c in
            Button { pick(c); dismiss() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("/\(c.name)").font(.body.monospaced().bold())
                        if let hint = c.argumentHint { Text(hint).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                    Text(c.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Changes

/// Uncommitted changes in the session's folder, file by file.
struct ChangesView: View {
    @Environment(Client.self) private var client
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var report: ChangesReport?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let report, report.repo {
                    List {
                        Section {
                            ForEach(report.files) { f in
                                NavigationLink { FileDiffView(file: f) } label: { FileRow(file: f) }
                            }
                        } header: {
                            if let branch = report.branch { Label(branch, systemImage: "arrow.triangle.branch") }
                        } footer: {
                            if report.files.isEmpty { Text("No uncommitted changes.") }
                            else if let total = report.total, total > report.files.count { Text("Showing \(report.files.count) of \(total) files.") }
                            else { Text("Everything changed since the last commit in this folder.") }
                        }
                    }
                } else if report != nil {
                    ContentUnavailableView("Not a git project", systemImage: "folder", description: Text("Changes are shown for folders under git."))
                } else if let error {
                    ContentUnavailableView("Couldn't load changes", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        do { report = try await client.changes(id); error = nil }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

struct FileRow: View {
    let file: ChangesReport.File

    var body: some View {
        let (icon, color): (String, Color) = switch file.status {
        case "added": ("plus.square.fill", .green)
        case "deleted": ("minus.square.fill", .red)
        case "renamed": ("arrow.right.square.fill", .purple)
        default: ("pencil.circle.fill", .orange)
        }
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: file.path).lastPathComponent).lineLimit(1)
                let dir = (file.path as NSString).deletingLastPathComponent
                if !dir.isEmpty { Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            Spacer()
            if let a = file.added { Text("+\(a)").font(.caption.monospacedDigit()).foregroundStyle(.green) }
            if let r = file.removed { Text("−\(r)").font(.caption.monospacedDigit()).foregroundStyle(.red) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct FileDiffView: View {
    let file: ChangesReport.File

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                let lines = (file.diff ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                if lines.allSatisfy(\.isEmpty) {
                    Text(file.status == "renamed" ? "Renamed, no content changes." : "No text changes to show (binary file or empty).")
                        .foregroundStyle(.secondary).padding()
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(.caption.monospaced())
                        .foregroundStyle(line.hasPrefix("@@") ? Color.purple : .primary)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            line.hasPrefix("+") && !line.hasPrefix("+++") ? Color.green.opacity(0.15)
                            : line.hasPrefix("-") && !line.hasPrefix("---") ? Color.red.opacity(0.15) : Color.clear
                        )
                }
                if file.truncated == true {
                    Text("Diff cut short. Open the file on your Mac for the rest.").font(.caption).foregroundStyle(.secondary).padding()
                }
            }
            .textSelection(.enabled)
        }
        .navigationTitle(URL(fileURLWithPath: file.path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Share

struct ShareText: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet for a file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Live Activity

/// Starts, updates and ends the lock-screen Live Activity for sessions running from this app.
@MainActor
enum LiveActivities {
    static func update(sessionId: String, title: String, status: String?, detail: String, requestId: String?) {
        let activity = Activity<SessionActivityAttributes>.activities.first { $0.attributes.sessionId == sessionId }
        let state = SessionActivityAttributes.ContentState(
            status: status ?? "closed", title: title, detail: String(detail.prefix(120)),
            requestId: requestId, updatedAt: Date().timeIntervalSince1970
        )
        if let activity {
            Task {
                if status == nil { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 15 * 60)) }
                else { await activity.update(.init(state: state, staleDate: nil)) }
            }
        } else if status == "running" || status == "waiting",
                  Prefs.liveActivities, ActivityAuthorizationInfo().areActivitiesEnabled {
            // Push updates (the server sends them while the app is closed) need a push token per activity.
            guard let started = try? Activity.request(
                attributes: SessionActivityAttributes(sessionId: sessionId),
                content: .init(state: state, staleDate: nil),
                pushType: .token
            ) else { return }
            Task {
                for await token in started.pushTokenUpdates {
                    await Client.shared.registerActivity(sessionId, token: token.map { String(format: "%02x", $0) }.joined())
                }
            }
        }
    }
}
