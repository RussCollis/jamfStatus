import SwiftUI

// Wrapper that injects openSettings from the environment on macOS 14+,
// falling back to sendAction on macOS 13. Needed because @Environment(\.openSettings)
// cannot be guarded with @available on a stored property.
@available(macOS 14.0, *)
private struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var monitor: MonitorViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "about")
        }

        Divider()

        if #available(macOS 14.0, *) {
            SettingsButton()
        } else {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }

        Button("Check for Updates…") {
            checkForUpdates()
        }

        Divider()

        Button("View Status Page") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "cloud-status")
        }

        Button("View Log") {
            showLogs()
        }

        Divider()

        Button("Health Status…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "health-status")
        }

        // Connection status light for each Jamf Pro instance; selecting one opens it in the browser.
        // Emoji are used because menu bar menus don't reliably render custom image icons.
        ForEach(monitor.instances) { instance in
            let connected = monitor.status(for: instance.id).connection == .connected
            Button("\(connected ? "🟢" : "🔴") \(instance.displayName)") {
                if let url = URL(string: instance.url) {
                    NSWorkspace.shared.open(url)
                }
            }
            .help(instance.url)
        }

        if monitor.totalNotificationCount > 0 {
            Menu("Notifications (\(monitor.totalNotificationCount))") {
                if monitor.instances.count == 1, let instance = monitor.instances.first {
                    notificationItems(for: instance)
                } else {
                    // Group notifications by instance when monitoring more than one server
                    ForEach(monitor.instances) { instance in
                        let count = monitor.status(for: instance.id).notifications.count
                        if count > 0 {
                            Menu("\(instance.displayName) (\(count))") {
                                notificationItems(for: instance)
                            }
                        }
                    }
                }
            }
        }


        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }

    @ViewBuilder
    private func notificationItems(for instance: JamfInstance) -> some View {
        ForEach(monitor.status(for: instance.id).notifications) { note in
            Text(note.displayTitle)
        }
    }

    private func checkForUpdates() {
        let version = AppInfo.version
        VersionCheck().versionCheck { updateAvailable in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText     = "Running jamfStatus: \(version)"
                alert.informativeText = updateAvailable
                    ? "A new version is available."
                    : "No updates are currently available."
                alert.alertStyle = .informational
                if updateAvailable {
                    alert.addButton(withTitle: "View")
                    alert.addButton(withTitle: "Ignore")
                } else {
                    alert.addButton(withTitle: "OK")
                }
                let response = alert.runModal()
                if response == .alertFirstButtonReturn && updateAvailable {
                    if let url = URL(string: "https://github.com/jamf/jamfStatus/releases") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func showLogs() {
        let path = (Log.path ?? "") + Log.file
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
