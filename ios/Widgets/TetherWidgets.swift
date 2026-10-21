import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@main
struct TetherWidgets: WidgetBundle {
    var body: some Widget { SessionLiveActivity() }
}

private struct Look {
    let label: String
    let icon: String
    let color: Color

    init(_ status: String) {
        switch status {
        case "waiting": (label, icon, color) = ("Needs you", "hand.raised.fill", .orange)
        case "running": (label, icon, color) = ("Working", "ellipsis.circle.fill", .blue)
        case "idle": (label, icon, color) = ("Done", "checkmark.circle.fill", .green)
        default: (label, icon, color) = ("Ended", "stop.circle.fill", .gray)
        }
    }
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding()
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
                .widgetURL(URL(string: "tether://session/\(context.attributes.sessionId)"))
        } dynamicIsland: { context in
            let look = Look(context.state.status)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: look.icon).font(.title2).foregroundStyle(look.color)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(look.label).font(.caption.bold()).foregroundStyle(look.color)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !context.state.detail.isEmpty {
                            Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        DecisionButtons(context: context)
                    }
                }
            } compactLeading: {
                Image(systemName: look.icon).foregroundStyle(look.color)
            } compactTrailing: {
                Text(look.label).font(.caption2.bold()).foregroundStyle(look.color)
            } minimal: {
                Image(systemName: look.icon).foregroundStyle(look.color)
            }
            .widgetURL(URL(string: "tether://session/\(context.attributes.sessionId)"))
        }
    }
}

struct LockScreenView: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    var body: some View {
        let look = Look(context.state.status)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "terminal.fill").foregroundStyle(.orange)
                Text(context.state.title).font(.headline).lineLimit(1)
                Spacer()
                Label(look.label, systemImage: look.icon).font(.caption.bold()).foregroundStyle(look.color)
            }
            if !context.state.detail.isEmpty {
                Text(context.state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            DecisionButtons(context: context)
        }
    }
}

/// Allow / Deny, only while Claude waits for an answer.
struct DecisionButtons: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    var body: some View {
        if context.state.status == "waiting", let request = context.state.requestId {
            HStack {
                Button(intent: DecideIntent(sessionId: context.attributes.sessionId, requestId: request, allow: false)) {
                    Label("Deny", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .tint(.red)
                Button(intent: DecideIntent(sessionId: context.attributes.sessionId, requestId: request, allow: true)) {
                    Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .tint(.green)
            }
            .buttonStyle(.borderedProminent)
            .font(.subheadline.bold())
        }
    }
}
