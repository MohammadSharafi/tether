import SwiftUI

@MainActor @Observable
final class SessionModel {
    var events: [Event] = []
    var state: String?            // live state on the server; nil = not running through this app
    var mode = "default"
    var model: String?
    var effort = "default"
    var title = ""
    private var detail = ""
    var usage: Usage?
    var cost: Double?
    var decided: [String: Bool] = [:]
    var alwaysAllowed: Set<String> = []
    var streaming = ""
    var error: String?
    var loaded = false
    private var lastSeq = 0
    // Owned by the model, not the view: SwiftUI's split view can report the screen as gone while it is still
    // showing, which used to cancel the load and leave the spinner up. These end in stop() or deinit.
    @ObservationIgnored nonisolated(unsafe) private var stream: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var life: Task<Void, Never>?
    /// Set by the view: the session runs in Terminal or the desktop app, so re-read it now and then.
    @ObservationIgnored var watchMac = false
    private var client: Client?
    private var id = ""

    var isLive: Bool { state != nil && state != "closed" }
    var isBusy: Bool { state == "running" || state == "waiting" }
    var pendingCount: Int { isLive ? events.filter { $0.kind == "permission" && decided[$0.requestID ?? ""] == nil }.count : 0 }
    var turnsFinished: Int { events.filter { $0.kind == "result" }.count }

    /// Returns false when the session could not be read, so the caller can try again.
    @discardableResult
    func load(_ client: Client, id: String) async -> Bool {
        self.client = client
        self.id = id
        // Seen before in this run: show that copy at once while the fresh one loads.
        if !loaded, let cached = client.detailCache[id] {
            show(cached)
            loaded = true
        }
        do {
            try await read()
            if isLive { follow() }
            loaded = true
            return true
        } catch is CancellationError where Task.isCancelled {
            return false // the view went away or a newer load replaced this one
        } catch is CancellationError {
            self.error = "Loading was interrupted. Retrying…"
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
        return false
    }

    /// Reads the session from the Mac and shows it.
    private func read() async throws {
        guard let client else { return }
        let d = try await client.detail(id)
        client.detailCache[id] = d
        show(d)
        error = nil
    }

    private func show(_ d: SessionDetail) {
        events = []
        decided = [:]
        streaming = ""
        d.events.forEach(apply)
        usage = d.usage
        state = d.state
        if let m = d.mode { mode = m }
        if let e = d.effort { effort = e }
        model = d.model ?? model
        lastSeq = d.seq
    }

    /// Re-reads a session that runs elsewhere on the Mac; only touches the view when something changed.
    func refresh() async {
        guard let client, !isLive, let d = try? await client.detail(id) else { return }
        client.detailCache[id] = d
        // Keep the rows already shown (same ids, so the list does not jump) and add only the new ones.
        // The server sends the last 300 events, so the old rows may have slid off the front.
        let old = events.map { "\($0.kind)\($0.text ?? "")" }
        let new = d.events.map { "\($0.kind)\($0.text ?? "")" }
        if old != new {
            if let k = old.indices.first(where: { Array(old[$0...]) == Array(new.prefix(old.count - $0)) }) {
                events.removeFirst(k)
                d.events.dropFirst(old.count - k).forEach(apply)
            } else {
                events = []
                d.events.forEach(apply)
            }
        }
        usage = d.usage
    }

    @discardableResult
    func send(text: String, images: [Attachment]) async -> Bool {
        guard let client else { return false }
        do {
            let wasLive = isLive
            // Mode and model ride along when this message resumes the session.
            try await client.send(id, text: text, images: images, mode: wasLive ? nil : mode, model: wasLive ? nil : model, effort: wasLive ? nil : effort)
            // A resumed session restarts its event numbering, so read it from the start.
            if !wasLive { lastSeq = 0; state = "running" }
            follow()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func decide(request: String, allow: Bool, always: Bool = false, answers: [String: String]? = nil, message: String? = nil) async {
        do { try await client?.decide(id, request: request, allow: allow, always: always, answers: answers, message: message) }
        catch { self.error = error.localizedDescription }
    }

    func setMode(_ m: String) async {
        mode = m
        if isLive { await run { try await $0.setSettings(self.id, mode: m) } }
    }

    func setEffort(_ e: String) async {
        effort = e
        if isLive { await run { try await $0.setSettings(self.id, effort: e) } }
    }

    func setModel(_ m: String) async {
        model = m
        if isLive { await run { try await $0.setSettings(self.id, model: m) } }
    }

    func interrupt() async { await run { try await $0.interrupt(self.id) } }
    func end() async { await run { try await $0.close(self.id) } }

    private func run(_ work: (Client) async throws -> Void) async {
        guard let client else { return }
        do { try await work(client) } catch { self.error = error.localizedDescription }
    }

    /// Loads the session (retrying until it works), then keeps a session that runs on the Mac up to date.
    /// `fresh` drops a load that may be hanging and starts over.
    func start(_ client: Client, id: String, fresh: Bool = false) {
        if fresh { life?.cancel(); life = nil }
        guard life == nil else { return }
        life = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.load(client, id: id) { break }
                try? await Task.sleep(for: .seconds(3))
            }
            var watched = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                if self.watchMac {
                    await self.refresh()
                    watched = true
                } else if watched {
                    // It stopped running on the Mac: read the final transcript once.
                    watched = false
                    if !self.isLive { await self.load(client, id: id) }
                }
            }
        }
    }

    func stop() {
        life?.cancel()
        life = nil
        stream?.cancel()
        stream = nil
    }

    deinit {
        life?.cancel()
        stream?.cancel()
    }

    private func follow() {
        guard stream == nil, let client else { return }
        let id = id
        stream = Task {
            var dropped = false
            do {
                for try await e in client.events(id, after: lastSeq) { apply(e) }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; dropped = true }
            }
            // The connection dropped (Mac restarting, network change): reconnect by reading the
            // session again until it works. `stream` stays set meanwhile, so stop() still cancels this.
            while dropped && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled, (try? await read()) != nil { break }
            }
            let resume = dropped && !Task.isCancelled && isLive
            stream = nil
            if resume { follow() }
        }
    }

    /// Keeps the lock-screen Live Activity in step with live events (only for events streamed now, not history).
    private func activity(_ e: Event) {
        guard e.seq != nil else { return }
        switch e.kind {
        case "tool": detail = "\(e.name ?? "Tool"): \(e.text ?? "")"
        case "assistant": detail = e.text ?? detail
        case "permission": detail = e.title ?? "\(e.name ?? "A tool"): \(e.text ?? "")"
        case "status", "permissionResolved", "result": break
        default: return
        }
        let waiting = events.last { $0.kind == "permission" && decided[$0.requestID ?? ""] == nil && $0.name != "AskUserQuestion" && $0.name != "ExitPlanMode" }
        LiveActivities.update(sessionId: id, title: title, status: state, detail: detail, requestId: state == "waiting" ? waiting?.requestID : nil)
    }

    private func apply(_ e: Event) {
        if let seq = e.seq { lastSeq = seq }
        defer { activity(e) }
        switch e.kind {
        case "status":
            state = e.state == "closed" ? nil : e.state
        case "permissionResolved":
            if let req = e.requestID {
                decided[req] = e.allow ?? false
                if e.always == true { alwaysAllowed.insert(req) }
            }
        case "delta":
            streaming += e.text ?? ""
        case "settings":
            if let m = e.mode { mode = m }
            if let x = e.effort { effort = x }
            model = e.model ?? model
        case "result":
            streaming = ""
            cost = e.cost
            events.append(e)
            Task { if let u = try? await client?.detail(id).usage { usage = u } }
        default:
            if ["assistant", "tool", "permission"].contains(e.kind) { streaming = "" }
            events.append(e)
        }
    }
}

struct SessionView: View {
    let id: String
    let title: String?
    var mac: MacRun?
    @Environment(Client.self) private var client
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = SessionModel()
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var shownTitle: String?
    @State private var confirmStop = false
    @State private var pendingSend: PendingSend?
    @State private var askContinue = false
    @State private var backgrounded = false
    @State private var loadAttempt = 0
    @State private var showChanges = false
    @State private var showCommands = false
    @State private var commands: [SlashCommand]?
    @State private var commandsError: String?
    @State private var share: ShareText?
    @AppStorage(Prefs.pinnedKey) private var pinned: [String] = []
    @AppStorage(Prefs.hapticsKey) private var haptics = true
    @FocusState private var composerFocused: Bool

    private var runningElsewhere: Bool { mac != nil }

    var body: some View {
        screen
        .alert("Rename session", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                let t = newTitle
                Task {
                    try? await client.rename(id, title: t)
                    shownTitle = t
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Stop this session on your Mac?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop on Mac", role: .destructive) { Task { await stopOnMac() } }
        } message: {
            Text("Claude Code stops in the \(mac?.place ?? "Mac"), like pressing Ctrl-C there. Then you can continue it from here.")
        }
        .confirmationDialog("Continue this chat on your phone?", isPresented: $askContinue, titleVisibility: .visible, presenting: pendingSend) { p in
            Button("Continue here") { Task { await continueHere(p) } }
            Button("Cancel", role: .cancel) { restore(p.text, p.images) }
        } message: { _ in
            Text("It is open in the \(mac?.place ?? "Mac"). Tether stops it there first, like pressing Ctrl-C, then sends your message. Reopen it on the Mac later to see the new messages.")
        }
        .sensoryFeedback(.warning, trigger: model.pendingCount) { old, new in haptics && new > old }
        .sensoryFeedback(.success, trigger: model.turnsFinished) { old, new in haptics && new > old && old > 0 }
        .sheet(isPresented: $showChanges) { ChangesView(id: id) }
        .sheet(isPresented: $showCommands) {
            CommandsSheet(commands: commands, error: commandsError) { c in use(c) }
                .task { await loadCommands() }
        }
        .sheet(item: $share) { ShareSheet(url: $0.url).presentationDetents([.medium, .large]) }
        .onChange(of: draft) { if draft.hasPrefix("/") && commands == nil { Task { await loadCommands() } } }
        .onAppear { model.title = shownTitle ?? title ?? "Session" }
        .onAppear {
            model.watchMac = runningElsewhere
            model.start(client, id: id)
        }
        .onChange(of: runningElsewhere) { model.watchMac = runningElsewhere }
        // Try again: drop a load that may be hanging and start over.
        .onChange(of: loadAttempt) { model.start(client, id: id, fresh: true) }
        // The background stops the event stream; coming back reads the session again.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stop(); backgrounded = true }
            if phase == .active && backgrounded {
                backgrounded = false
                loadAttempt += 1
            }
        }
    }

    private func loadCommands() async {
        guard commands == nil else { return }
        do { commands = try await client.commands(id) } catch { commandsError = error.localizedDescription }
    }

    /// Puts a command in the message box; commands that take no arguments are sent right away.
    private func use(_ c: SlashCommand) {
        if c.argumentHint == nil && !runningElsewhere {
            draft = ""
            Task { await model.send(text: "/\(c.name)", images: []) }
        } else {
            draft = "/\(c.name) "
            composerFocused = true
        }
    }

    private func fork() async {
        do {
            let newID = try await client.fork(id)
            client.listVersion += 1
            client.openSessionID = newID
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func shareTranscript() async {
        do {
            let md = try await client.export(id)
            let safe = (shownTitle ?? title ?? "Claude session").replacingOccurrences(of: "/", with: "-").prefix(60)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).md")
            try md.write(to: url, atomically: true, encoding: .utf8)
            share = ShareText(url: url)
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func stopOnMac() async {
        do {
            try await client.stopOnMac(id)
            client.listVersion += 1
        } catch {
            model.error = error.localizedDescription
        }
    }

    private var screen: some View {
        transcript
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if !model.loaded {
                Loading { loadAttempt += 1 }
            } else if model.events.isEmpty, let error = model.error {
                // Nothing to show yet, so the problem goes in the middle of the screen. It keeps retrying.
                ContentUnavailableView {
                    Label("Can't load this session", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { loadAttempt += 1 }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(shownTitle ?? title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { titleView }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
    }

    // Chat-style list in natural order, kept pinned to the newest event.
    private var transcript: some View {
        GeometryReader { geo in
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.loaded { SessionHeader(model: model) }
                    ForEach(model.events) { e in
                        EventRow(event: e, model: model)
                    }
                    if !model.streaming.isEmpty {
                        MarkdownText(text: model.streaming + " ▍")
                    }
                    if let error = model.error, !model.events.isEmpty { // an empty session shows it mid-screen
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.red)
                            Spacer(minLength: 0)
                            Button("Try again") { loadAttempt += 1 }
                                .font(.footnote.bold())
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
                // A short chat still fills the screen, with its messages at the bottom, so "the bottom"
                // is one fixed scroll position instead of one the scroll view has to guess.
                .frame(minHeight: geo.size.height, alignment: .bottom)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(StayAtBottom())
            // A fresh list of messages gets a fresh scroll view, so it opens at the newest message
            // (lazy rows only guess their heights, and a late scroll can land in empty space).
            .id(model.events.first?.id)
            // Lazy rows guess their heights, so the first jump can land short; jump again once they are measured.
            .task(id: model.events.count) {
                for delay in [0, 150, 400] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        }
    }

    private var titleView: some View {
        VStack(spacing: 1) {
            Text(shownTitle ?? title ?? "Session").font(.headline).lineLimit(1)
            if let status = SessionStatus(state: model.state, mac: model.isLive ? nil : mac) {
                StatusLine(status: status).font(.caption2.weight(.semibold))
            }
        }
    }

    private var menu: some View {
        Menu {
            Menu {
                Picker("Permissions", selection: Binding(get: { model.mode }, set: { m in Task { await model.setMode(m) } })) {
                    ForEach(client.info?.modes ?? ["default"], id: \.self) { m in
                        Label(Mode.label(m), systemImage: Mode.icon(m)).tag(m)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Permissions: \(Mode.label(model.mode))", systemImage: Mode.icon(model.mode))
            }
            if let models = client.info?.models, !models.isEmpty {
                Menu {
                    Picker("Model", selection: Binding(get: { model.model ?? "default" }, set: { m in Task { await model.setModel(m) } })) {
                        ForEach(models, id: \.value) { m in Text(m.displayName).tag(m.value) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Model: \(modelName(models))", systemImage: "cpu")
                }
            }
            Menu {
                Picker("Effort", selection: Binding(get: { model.effort }, set: { e in Task { await model.setEffort(e) } })) {
                    ForEach(client.info?.efforts ?? Effort.all, id: \.self) { e in
                        Text(Effort.label(e)).tag(e)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Effort: \(Effort.label(model.effort))", systemImage: "gauge.with.dots.needle.50percent")
            }
            Divider()
            Button("Commands", systemImage: "slash.circle") { showCommands = true }
            Button("Changes", systemImage: "doc.badge.plus") { showChanges = true }
            Divider()
            Button(pinned.contains(id) ? "Unpin" : "Pin", systemImage: pinned.contains(id) ? "pin.slash" : "pin") { pinned.toggle(id) }
            Button("Fork session", systemImage: "arrow.triangle.branch") { Task { await fork() } }
            Button("Share transcript", systemImage: "square.and.arrow.up") { Task { await shareTranscript() } }
            Button("Rename", systemImage: "pencil") { newTitle = shownTitle ?? title ?? ""; renaming = true }
            if model.isBusy {
                Button("Stop this turn", systemImage: "stop.circle") { Task { await model.interrupt() } }
            }
            if model.isLive {
                Button("End session", systemImage: "xmark.circle", role: .destructive) { Task { await model.end() } }
            }
            if runningElsewhere && !model.isLive {
                Button("Stop on Mac", systemImage: "stop.circle", role: .destructive) { confirmStop = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle").accessibilityLabel("Session options")
        }
    }

    private func modelName(_ models: [ModelOption]) -> String {
        let id = model.model ?? "default"
        // The SDK reports the full id (claude-opus-5-5) after start; match it to an alias row when possible.
        return models.first { $0.value == id || id.contains($0.value) }?.displayName ?? prettyModel(id)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// Sends a message. A session open on the Mac is stopped there first, after the user agrees,
    /// because two programs writing one session would split it. A failed message goes back into the box.
    private func submit(_ text: String, _ images: [Attachment]) {
        if runningElsewhere && !model.isLive {
            pendingSend = PendingSend(text: text, images: images)
            askContinue = true
            return
        }
        Task {
            if !(await model.send(text: text, images: images)) { restore(text, images) }
        }
    }

    private func continueHere(_ p: PendingSend) async {
        do {
            try await client.stopOnMac(id)
            // Wait for the Mac process to exit; the server refuses the message while it runs.
            for _ in 0..<10 {
                try await Task.sleep(for: .seconds(1))
                if try await client.sessions().first(where: { $0.id == id })?.mac == nil { break }
            }
        } catch {
            model.error = error.localizedDescription
        }
        if await model.send(text: p.text, images: p.images) {
            client.listVersion += 1
        } else {
            restore(p.text, p.images)
        }
    }

    private func restore(_ text: String, _ images: [Attachment]) {
        if draft.isEmpty { draft = text }
        if attachments.isEmpty { attachments = images }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let mac, !model.isLive {
                Label("Open in the \(mac.place). Updates appear here live; send a message to continue it here.", systemImage: mac.icon)
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            composerField
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var composerField: some View {
        VStack(spacing: 6) {
            if draft.hasPrefix("/") && !draft.contains(" "), let commands {
                CommandSuggestions(commands: commands, query: draft) { use($0) }
            } else if draft.isEmpty && attachments.isEmpty && !model.isBusy && model.loaded {
                QuickReplyBar { reply in submit(reply, []) }
            }
            AttachmentStrip(attachments: $attachments)
            HStack(alignment: .bottom, spacing: 8) {
                AttachmentButton(attachments: $attachments)
                TextField("Message, or / for commands", text: $draft, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(composerFocused ? 0.25 : 0.08)))
                if model.isBusy && !canSend {
                    Button("Stop", systemImage: "stop.circle.fill") { Task { await model.interrupt() } }
                        .labelStyle(.iconOnly).font(.title).tint(.red)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") {
                        let text = draft, images = attachments
                        draft = ""
                        attachments = []
                        submit(text, images)
                    }
                    .labelStyle(.iconOnly).font(.title)
                    .disabled(!canSend)
                }
            }
        }
    }
}

/// Shown above the oldest message: tokens, cost and permission mode.
struct SessionHeader: View {
    let model: SessionModel

    var body: some View {
        if let u = model.usage, (u.input ?? 0) + (u.output ?? 0) + (u.cacheRead ?? 0) > 0 {
            HStack(spacing: 14) {
                Label(short((u.input ?? 0) + (u.cacheRead ?? 0) + (u.cacheWrite ?? 0)), systemImage: "arrow.down.circle")
                Label(short(u.output), systemImage: "arrow.up.circle")
                if let cost = model.cost, cost > 0 {
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                }
                Spacer()
                Label(Mode.label(model.mode), systemImage: Mode.icon(model.mode))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tokens in \(short((u.input ?? 0) + (u.cacheRead ?? 0) + (u.cacheWrite ?? 0))), out \(short(u.output)). \(Mode.label(model.mode)).")
        }
    }
}

func short(_ n: Int?) -> String { (n ?? 0).formatted(.number.notation(.compactName)) }

struct EventRow: View {
    let event: Event
    let model: SessionModel
    @State private var expanded = false
    @AppStorage(Prefs.showToolsKey) private var showTools = true

    var body: some View {
        let text = event.text ?? ""
        switch event.kind {
        case "user":
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 4) {
                    if let n = event.images, n > 0 {
                        Label("\(n) photo\(n == 1 ? "" : "s")", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                    }
                    if !text.isEmpty {
                        Text(text)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.accentGradient, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
                            .shadow(color: Color.accentColor.opacity(0.25), radius: 8, y: 3)
                            .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text } }
                    }
                }
            }
        case "assistant":
            MarkdownText(text: text)
                .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text } }
        case "tool":
            if showTools { ToolRow(event: event) }
        case "meta":
            Text(text)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(expanded ? nil : 1)
                .onTapGesture { expanded.toggle() }
        case "permission":
            PermissionCard(event: event, model: model)
        case "result":
            HStack(spacing: 6) {
                Image(systemName: event.isError == true ? "exclamationmark.triangle" : "checkmark.circle")
                Text(event.isError != true ? "Done" : text.isEmpty ? "Stopped" : "Stopped: \(text.replacingOccurrences(of: "_", with: " "))")
                if let cost = event.cost, cost > 0 {
                    Text("·")
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                }
            }
            .font(.caption)
            .foregroundStyle(event.isError == true ? .orange : .secondary)
        case "notice":
            NoticeRow(event: event)
        case "error":
            Label(text, systemImage: "exclamationmark.octagon").font(.footnote).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}

struct NoticeRow: View {
    let event: Event

    private var message: String {
        let reset = event.resetsAt.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
        if event.status == "credits" {
            return "This model needs extra usage credits on your Claude plan. Pick another model in ••• → Model (Opus or Sonnet), then send again."
        }
        if event.status == "auth" {
            return "Claude Code on your Mac is logged out. On the Mac, run claude and type /login, then send your message again."
        }
        if event.status == "rejected" {
            return "Usage limit reached" + (reset.map { " · resets \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        }
        return "Approaching your usage limit" + (event.utilization.map { " (\(Int($0 * 100))%)" } ?? "")
    }

    var body: some View {
        Label(message, systemImage: "gauge.with.dots.needle.67percent")
            .font(.footnote)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

func toolIcon(_ name: String?) -> String {
    switch name {
    case "Bash": "terminal"
    case "Edit", "MultiEdit", "Write", "NotebookEdit": "pencil.line"
    case "Read": "doc.text"
    case "Grep", "Glob": "magnifyingglass"
    case "WebFetch", "WebSearch": "globe"
    case "Task", "Agent": "person.2"
    case "TodoWrite": "checklist"
    case "AskUserQuestion": "questionmark.bubble"
    case "ExitPlanMode": "list.bullet.clipboard"
    default: "wrench.and.screwdriver"
    }
}

/// A tool call: one line, expandable to the diff or full command when there is more to see.
struct ToolRow: View {
    let event: Event
    @State private var expanded = false

    private var expandable: Bool {
        guard let i = event.input else { return false }
        return i.old_string != nil || i.edits != nil || i.content != nil || i.plan != nil || (i.command?.count ?? 0) > 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: toolIcon(event.name)).frame(width: 18)
                    // MCP tools are named mcp__<server>__<tool>; the tool part is the readable one.
                    Text(event.name.map { $0.hasPrefix("mcp__") ? ($0.components(separatedBy: "__").last ?? $0) : $0 } ?? "Tool").bold()
                    Text(event.text ?? "").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if expandable { Image(systemName: expanded ? "chevron.up" : "chevron.down").imageScale(.small) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!expandable)
            if expanded, let input = event.input { ToolInputView(input: input) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Renders a tool's input: diffs for edits, the command for Bash, the plan for plan mode.
struct ToolInputView: View {
    let input: ToolInput

    var body: some View {
        if let plan = input.plan {
            ScrollView { MarkdownText(text: plan) }
                .frame(maxHeight: 360)
        } else if input.old_string != nil || input.edits != nil || input.content != nil {
            DiffView(input: input)
        } else if let command = input.command {
            VStack(alignment: .leading, spacing: 4) {
                if let d = input.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                Text(command)
                    .font(.callout.monospaced())
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
        }
    }
}

struct DiffView: View {
    let input: ToolInput
    private let maxLines = 80

    private var lines: [(sign: String, text: String)] {
        func split(_ s: String?) -> [String] {
            s.map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
        }
        // Lines shared at the start and end of an edit are context, shown once.
        func hunk(_ old: [String], _ new: [String]) -> [(sign: String, text: String)] {
            var head = 0
            while head < min(old.count, new.count) && old[head] == new[head] { head += 1 }
            var tail = 0
            while tail < min(old.count, new.count) - head && old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
            return old[..<head].map { (" ", $0) }
                + old[head..<(old.count - tail)].map { ("-", $0) }
                + new[head..<(new.count - tail)].map { ("+", $0) }
                + old[(old.count - tail)...].map { (" ", $0) }
        }
        let pairs = input.edits?.map { ($0.old_string, $0.new_string) } ?? [(input.old_string, input.new_string)]
        return pairs.flatMap { hunk(split($0.0), split($0.1)) } + split(input.content).map { ("+", $0) }
    }

    var body: some View {
        let all = lines
        VStack(alignment: .leading, spacing: 0) {
            if let path = input.file_path {
                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc")
                    .font(.caption.bold())
                    .padding(.bottom, 4)
            }
            ForEach(Array(all.prefix(maxLines).enumerated()), id: \.offset) { _, line in
                Text("\(line.sign) \(line.text)")
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .foregroundStyle(line.sign == " " ? .secondary : .primary)
                    .background(line.sign == "-" ? Color.red.opacity(0.14) : line.sign == "+" ? Color.green.opacity(0.14) : Color.secondary.opacity(0.06))
            }
            if all.count > maxLines {
                Text("\(all.count - maxLines) more lines").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Changes to \(input.file_path ?? "file"): \(all.filter { $0.sign == "-" }.count) lines removed, \(all.filter { $0.sign == "+" }.count) added")
    }
}

struct PermissionCard: View {
    let event: Event
    let model: SessionModel
    @State private var feedback = ""
    @State private var askingFeedback = false
    @State private var sending = false

    private var request: String { event.requestID ?? "" }
    private var decision: Bool? { model.decided[request] }
    private var pending: Bool { decision == nil && model.isLive }
    private var isPlan: Bool { event.name == "ExitPlanMode" }
    private var isQuestion: Bool { event.name == "AskUserQuestion" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(heading, systemImage: isPlan ? "list.bullet.clipboard" : isQuestion ? "questionmark.bubble" : "hand.raised")
                .font(.subheadline.bold())
            if let questions = event.input?.questions {
                QuestionForm(questions: questions, enabled: pending) { answers in
                    act { await model.decide(request: request, allow: true, answers: answers) }
                }
            } else if let input = event.input {
                ToolInputView(input: input)
            } else {
                Text(event.text ?? "").font(.callout.monospaced()).textSelection(.enabled)
            }
            footer
        }
        .padding()
        .background(Color.accentColor.opacity(pending ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.accentColor.opacity(pending ? 0.5 : 0.12), lineWidth: pending ? 1.5 : 1))
        .alert(isPlan ? "What should change in the plan?" : "Tell Claude what to do instead", isPresented: $askingFeedback) {
            TextField("Optional note", text: $feedback)
            Button(isPlan ? "Keep planning" : "Deny") {
                let note = feedback
                act { await model.decide(request: request, allow: false, message: note) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var heading: String {
        if isPlan { return "Plan ready for review" }
        if isQuestion { return "Claude has a question" }
        return event.title ?? "Claude wants to use \(event.name ?? "a tool")"
    }

    private var outcome: String {
        guard let decision else { return "" }
        if isPlan { return decision ? "Plan approved" : "Kept planning" }
        if isQuestion { return decision ? "Answered" : "Skipped" }
        if decision && model.alwaysAllowed.contains(request) { return "Always allowed" }
        return decision ? "Allowed" : "Denied"
    }

    @ViewBuilder private var footer: some View {
        if let decision {
            Label(outcome, systemImage: decision ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(decision ? .green : .red)
        } else if !model.isLive {
            Text("No longer waiting").font(.caption).foregroundStyle(.secondary)
        } else if isQuestion {
            Button("Skip question", role: .destructive) {
                act { await model.decide(request: request, allow: false, message: "The user skipped the question.") }
            }
            .font(.footnote)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }
            .disabled(sending)
        }
    }

    @ViewBuilder private var buttons: some View {
        Button(isPlan ? "Keep planning" : "Deny", role: .destructive) { feedback = ""; askingFeedback = true }
            .buttonStyle(.bordered)
        if event.canAlways == true && !isPlan {
            Button("Always allow") { act { await model.decide(request: request, allow: true, always: true) } }
                .buttonStyle(.bordered)
        }
        Button(isPlan ? "Approve plan" : "Allow") { act { await model.decide(request: request, allow: true) } }
            .buttonStyle(.borderedProminent)
    }

    private func act(_ work: @escaping () async -> Void) {
        sending = true
        Task { await work(); sending = false }
    }
}

struct QuestionForm: View {
    let questions: [Question]
    let enabled: Bool
    let submit: ([String: String]) -> Void
    @State private var picked: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    private func answer(_ q: Question) -> String {
        let typed = other[q.question, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return q.options.map(\.label).filter { picked[q.question, default: []].contains($0) }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(questions, id: \.question) { q in
                VStack(alignment: .leading, spacing: 8) {
                    if let h = q.header {
                        Text(h.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
                    }
                    Text(q.question).font(.callout.weight(.semibold))
                    ForEach(q.options, id: \.label) { o in
                        optionRow(q, o)
                    }
                    TextField("Other answer", text: Binding(get: { other[q.question, default: ""] }, set: { other[q.question] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                }
            }
            if enabled {
                Button(questions.count > 1 ? "Send answers" : "Send answer") {
                    submit(Dictionary(uniqueKeysWithValues: questions.map { ($0.question, answer($0)) }))
                }
                .buttonStyle(.borderedProminent)
                .disabled(questions.contains { answer($0).isEmpty })
            }
        }
        .disabled(!enabled)
    }

    private func optionRow(_ q: Question, _ o: Question.Option) -> some View {
        let multi = q.multiSelect == true
        let on = picked[q.question, default: []].contains(o.label)
        return Button {
            var set = multi ? picked[q.question, default: []] : []
            if on { set.remove(o.label) } else { set.insert(o.label) }
            picked[q.question] = set
            other[q.question] = ""
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.label)
                    if let d = o.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Light Markdown: headings, bullets, code blocks and tables, with inline styles.
struct MarkdownText: View {
    let text: String

    enum Block { case heading(Int, String), bullet(String, String), code(String), table([[String]]), paragraph(String) }

    /// Cells of a Markdown table row ("| a | b |"), or nil for the "|---|:--:|" separator row.
    static func tableCells(_ line: String) -> [String]? {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        let cells = body.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let isSeparator = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }
        return isSeparator ? nil : cells
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = [], code: [String] = []
        var inCode = false
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode { out.append(.code(code.joined(separator: "\n"))); code = [] } else { flush() }
                inCode.toggle()
            } else if inCode {
                code.append(raw)
            } else if line.hasPrefix("|") {
                flush()
                let row = Self.tableCells(line)
                if case .table(let rows) = out.last {
                    if let row { out[out.count - 1] = .table(rows + [row]) }
                } else {
                    out.append(.table(row.map { [$0] } ?? []))
                }
            } else if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)/) {
                flush()
                out.append(.heading(m.1.count, String(m.2)))
            } else if let m = line.firstMatch(of: /^([-*•]|\d+\.)\s+(.*)/) {
                flush()
                out.append(.bullet(m.1 == "-" || m.1 == "*" ? "•" : String(m.1), String(m.2)))
            } else if line.isEmpty {
                flush()
            } else {
                para.append(raw)
            }
        }
        if inCode { out.append(.code(code.joined(separator: "\n"))) }
        flush()
        return out
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    /// One block per data row, each cell labelled with its column header: fits any width without
    /// sideways scrolling, which suits long cells on a phone.
    private func table(_ rows: [[String]]) -> some View {
        let header = rows.first ?? []
        let data = rows.count > 1 ? Array(rows.dropFirst()) : rows
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(data.enumerated()), id: \.offset) { r, row in
                if r > 0 { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                        if !cell.isEmpty {
                            let label = rows.count > 1 && c < header.count && !header[c].isEmpty ? header[c] : nil
                            VStack(alignment: .leading, spacing: 1) {
                                if let label { Text(inline(label)).font(.caption.bold()).foregroundStyle(.secondary) }
                                Text(inline(cell)).font(c == 0 ? .subheadline.weight(.semibold) : .subheadline)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let s):
                    Text(inline(s)).font(level <= 1 ? .title3.bold() : .headline)
                case .bullet(let mark, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(mark).foregroundStyle(.secondary)
                        Text(inline(s))
                    }
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(s).font(.caption.monospaced()).padding(10)
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                case .table(let rows):
                    table(rows)
                case .paragraph(let s):
                    Text(inline(s))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PendingSend {
    let text: String
    let images: [Attachment]
}

/// The first load of a session. After a few seconds it explains and offers a retry.
private struct Loading: View {
    let retry: () -> Void
    @State private var slow = false

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            if slow {
                Text("Still loading. Check that your Mac is awake and on Tailscale.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { slow = false; retry() }
            }
        }
        .padding(32)
        .task(id: slow) {
            guard !slow else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { slow = true }
        }
    }
}

/// Keeps the newest message in view while lazy rows replace their guessed heights with real ones.
private struct StayAtBottom: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, *) { content.defaultScrollAnchor(.bottom, for: .sizeChanges) } else { content }
    }
}
