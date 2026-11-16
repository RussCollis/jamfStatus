import SwiftUI

/// A single notification line in the alert popup.
struct InstanceAlertItem {
    let title: String
    let acknowledged: Bool
}

/// Notifications for one instance, as shown in the alert popup.
struct InstanceAlertGroup: Identifiable {
    let id: UUID
    let instanceName: String
    let items: [InstanceAlertItem]
    /// Identifiers used to record acknowledgement of the unacknowledged notifications.
    let signatures: Set<String>

    var needsAttention: Bool { items.contains { !$0.acknowledged } }
}

struct InstanceAlertView: View {
    let groups: [InstanceAlertGroup]
    var onIgnore: (UUID) -> Void
    var onAcknowledge: (UUID) -> Void
    var onIgnoreAll: () -> Void
    var onAcknowledgeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                alertIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jamf Pro Notifications")
                        .font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        groupCard(group)
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Repeats every 15 minutes until acknowledged.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if attentionCount > 1 {
                    Button("Ignore All for 1 Hour", action: onIgnoreAll)
                    Button("Acknowledge All", action: onAcknowledgeAll)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 500)
    }

    private var attentionCount: Int { groups.filter(\.needsAttention).count }

    private var subtitle: String {
        switch attentionCount {
        case 0:  return "All notifications acknowledged"
        case 1:  return "1 server needs attention"
        default: return "\(attentionCount) servers need attention"
        }
    }

    /// App icon with a red alert badge (green check once everything is acknowledged).
    private var alertIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            Image(systemName: attentionCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 20, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, attentionCount > 0 ? Color.red : Color.green)
                .background(Circle().fill(.white).padding(2))
                .offset(x: 4, y: 4)
        }
        .frame(width: 56, height: 56)
    }

    private func groupCard(_ group: InstanceAlertGroup) -> some View {
        let tint: Color = group.needsAttention ? .red : .green
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(tint)
                Text(group.instanceName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if group.needsAttention {
                    Button("Ignore 1 Hour") { onIgnore(group.id) }
                        .controlSize(.small)
                    Button("Acknowledge") { onAcknowledge(group.id) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(attentionCount == 1 ? .defaultAction : nil)
                } else {
                    Label("Acknowledged", systemImage: "checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
            ForEach(group.items.indices, id: \.self) { i in
                let item = group.items[i]
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: item.acknowledged ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(item.acknowledged ? Color.green : Color.red)
                    Text(item.title)
                        .foregroundStyle(item.acknowledged ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Panel host

final class InstanceAlertPanel: NSPanel {

    struct Actions {
        var ignore: (UUID) -> Void
        var acknowledge: (UUID) -> Void
        var ignoreAll: () -> Void
        var acknowledgeAll: () -> Void
    }

    private let hosting: NSHostingView<InstanceAlertView>
    private let actions: Actions

    init(groups: [InstanceAlertGroup], actions: Actions) {
        self.actions = actions
        self.hosting = NSHostingView(rootView: InstanceAlertView(
            groups: groups,
            onIgnore: actions.ignore,
            onAcknowledge: actions.acknowledge,
            onIgnoreAll: actions.ignoreAll,
            onAcknowledgeAll: actions.acknowledgeAll
        ))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask:   [.titled, .closable, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )

        self.title                  = "jamfStatus"
        self.level                  = .floating
        self.isFloatingPanel        = true
        self.hidesOnDeactivate      = false
        self.becomesKeyOnlyIfNeeded = true
        self.isReleasedWhenClosed   = false
        self.collectionBehavior     = [.canJoinAllSpaces, .fullScreenAuxiliary]

        hosting.autoresizingMask = [.width, .height]
        self.contentView = hosting
        self.setContentSize(hosting.fittingSize)
    }

    /// Replaces the listed servers, e.g. after one is acknowledged, keeping the top-right corner fixed.
    func update(groups: [InstanceAlertGroup]) {
        let topRight = NSPoint(x: frame.maxX, y: frame.maxY)
        hosting.rootView = InstanceAlertView(
            groups: groups,
            onIgnore: actions.ignore,
            onAcknowledge: actions.acknowledge,
            onIgnoreAll: actions.ignoreAll,
            onAcknowledgeAll: actions.acknowledgeAll
        )
        setContentSize(hosting.fittingSize)
        setFrameTopLeftPoint(NSPoint(x: topRight.x - frame.width, y: topRight.y))
    }

    func showOnActiveScreen() {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.maxX - frame.width - 20
            let y = visible.maxY - frame.height - 20
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        orderFrontRegardless()
    }
}

#Preview {
    InstanceAlertView(
        groups: [
            InstanceAlertGroup(id: UUID(), instanceName: "DEVELOPMENT",
                               items: [InstanceAlertItem(title: "Connection to the APN Service Failed. Could not connect to the APNs server. The server is down or network is unreachable.", acknowledged: false)],
                               signatures: []),
            InstanceAlertGroup(id: UUID(), instanceName: "PRODUCTION",
                               items: [InstanceAlertItem(title: "Push Notification Certificate Expiring in 12 days", acknowledged: true)],
                               signatures: [])
        ],
        onIgnore: { _ in }, onAcknowledge: { _ in }, onIgnoreAll: {}, onAcknowledgeAll: {}
    )
}
