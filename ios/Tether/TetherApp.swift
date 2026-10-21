import SwiftUI
import UserNotifications

@main
struct TetherApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var client = Client.shared
    @AppStorage(Theme.appearanceKey) private var appearance = "dark"

    var body: some Scene {
        WindowGroup {
            SessionsView()
                .environment(client)
                .preferredColorScheme(Theme.scheme(appearance))
                // Confirmed in Settings: a sheet there is always on screen, while an alert here can be hidden by one.
                .onOpenURL { url in
                    // tether://session/<id> comes from tapping a Live Activity.
                    if url.host == "session", let id = url.pathComponents.last, id.count == 36 { client.openSessionID = id }
                    else { client.pendingPairing = Client.pairing(from: url) }
                }
        }
    }
}

enum Notifications {
    static let permissionCategory = "PERMISSION"

    static func register() {
        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: permissionCategory, actions: [allow, deny], intentIdentifiers: []),
        ])
    }

    static func requestPermission() {
        Task {
            let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
            if granted == true { await UIApplication.shared.registerForRemoteNotifications() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Notifications.register()
        Task {
            if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in Client.shared.deviceToken = hex }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // Lock-screen Allow / Deny, or a tap that opens the session.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let session = info["sessionId"] as? String else { return }
        let request = info["requestId"] as? String
        switch response.actionIdentifier {
        case "ALLOW", "DENY":
            guard let request else { return }
            try? await Client.shared.decide(session, request: request, allow: response.actionIdentifier == "ALLOW")
        default:
            await MainActor.run { Client.shared.openSessionID = session }
        }
    }
}

struct SettingsView: View {
    @Environment(Client.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: String?
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @AppStorage(Prefs.modeKey) private var mode = "default"
    @AppStorage(Prefs.modelKey) private var model = "default"
    @AppStorage(Prefs.effortKey) private var effort = "default"
    @AppStorage(Prefs.notifyNeedsYouKey) private var notifyNeedsYou = true
    @AppStorage(Prefs.notifyDoneKey) private var notifyDone = true
    @AppStorage(Prefs.showToolsKey) private var showTools = true
    @AppStorage(Prefs.hapticsKey) private var haptics = true
    @AppStorage(Theme.appearanceKey) private var appearance = "dark"
    @AppStorage(Prefs.liveActivityKey) private var liveActivities = true
    @AppStorage(Prefs.quickRepliesKey) private var quickReplies: [String] = Prefs.defaultQuickReplies

    private func test() async {
        status = "Connecting…"
        do {
            try await client.loadInfo()
            status = "Connected. \(try await client.sessions().count) sessions."
        } catch {
            status = error.localizedDescription
        }
    }

    var body: some View {
        @Bindable var client = client
        NavigationStack {
            Form {
                // A QR code could come from anyone: confirm before sending prompts to a new server.
                if let pairing = client.pendingPairing {
                    Section {
                        LabeledContent("Mac", value: URL(string: pairing.server)?.host ?? pairing.server)
                        Button("Connect") {
                            client.baseURL = pairing.server
                            client.token = pairing.token
                            client.pendingPairing = nil
                            Notifications.requestPermission()
                            Task { await test() }
                        }
                        .bold()
                        Button("Cancel", role: .cancel) { client.pendingPairing = nil }
                    } header: {
                        Text("Connect to this Mac?")
                    } footer: {
                        Text("Only connect to a Mac you set up yourself. Your prompts and approvals go to it.")
                    }
                }
                Section {
                    Label {
                        Text("On your Mac, run **npm run pair** in the server folder, then scan the QR code with the iPhone Camera.")
                    } icon: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                } header: {
                    Text("Pair with your Mac")
                }
                Section {
                    // verbatim: a String key is read as Markdown and the URL would render as a link
                    TextField(text: $client.baseURL, prompt: Text(verbatim: "https://your-mac.your-tailnet.ts.net")) { Text("Server address") }
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                    SecureField("Token", text: $client.token)
                        .textContentType(.password)
                    Button("Test connection") { Task { await test() } }
                    if let status { Text(status).foregroundStyle(.secondary) }
                } header: {
                    Text("Or enter it by hand")
                }
                Section {
                    switch notifications {
                    case .authorized, .provisional, .ephemeral:
                        Label("On", systemImage: "bell.badge")
                    case .denied:
                        Button("Turn on in iOS Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    default:
                        Button("Turn on notifications") { Notifications.requestPermission() }
                    }
                    Toggle("When Claude needs you", isOn: $notifyNeedsYou)
                    Toggle("When a turn finishes", isOn: $notifyDone)
                    Toggle("Live Activity on the lock screen", isOn: $liveActivities)
                    if client.info?.push == false {
                        Text("Your Mac isn't set up to send them yet. See “Push notifications” in the README.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Approve or deny right from the lock screen. The Live Activity shows what Claude is doing while a session runs from this phone.")
                }
                .onChange(of: notifyNeedsYou) { Task { await client.registerDevice() } }
                .onChange(of: notifyDone) { Task { await client.registerDevice() } }
                Section {
                    Picker("Permissions", selection: $mode) {
                        ForEach(client.info?.modes ?? ["default"], id: \.self) { m in Label(Mode.label(m), systemImage: Mode.icon(m)).tag(m) }
                    }
                    Picker("Model", selection: $model) {
                        ForEach(client.info?.models ?? [], id: \.value) { m in Text(m.displayName).tag(m.value) }
                    }
                    Picker("Effort", selection: $effort) {
                        ForEach(client.info?.efforts ?? Effort.all, id: \.self) { e in Text(Effort.label(e)).tag(e) }
                    }
                } header: {
                    Text("New sessions")
                } footer: {
                    Text("Used when you start a session. You can change them per session from its ••• menu.")
                }
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                        Text("System").tag("system")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Sessions") {
                    NavigationLink {
                        QuickRepliesEditor()
                    } label: {
                        LabeledContent("Quick replies", value: "\(quickReplies.count)")
                    }
                    Toggle("Show tool steps", isOn: $showTools)
                    Toggle("Haptics", isOn: $haptics)
                }
                if let info = client.info {
                    Section {
                        ForEach(info.accounts ?? [], id: \.dir) { a in
                            LabeledContent(a.name) {
                                switch a.loggedIn {
                                case true?: Label("Logged in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                case false?: Label("Logged out", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                                default: Text("Unknown").foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Claude Code on this Mac")
                    } footer: {
                        Text("Sessions from every folder are shown. New sessions use \(URL(fileURLWithPath: info.configDir).lastPathComponent). To log in, run claude on the Mac and type /login.")
                    }
                }
            }
            .tint(Color.accentColor) // orange switches instead of iOS green
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            // Re-read when the app is active again: the iOS permission prompt pauses the app while it is shown.
            .preferredColorScheme(Theme.scheme(appearance)) // an open sheet does not pick up the change from the window
            .task(id: scenePhase) { notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
        }
    }
}
