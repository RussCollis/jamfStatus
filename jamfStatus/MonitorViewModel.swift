import SwiftUI
import OSLog

// MARK: - ParsedNotification

struct ParsedNotification: Identifiable {
    let id = UUID()
    let displayTitle: String
    let key: String

    init?(raw: [String: Any]) {
        guard let alertTitle = raw["type"] as? String else { return nil }
        let titleKey = JamfNotification.key[alertTitle] ?? "Unknown"
        var title = JamfNotification.displayTitle[titleKey] ?? alertTitle

        switch titleKey {
        case "CERT_WILL_EXPIRE", "CERT_EXPIRED":
            let certType = JamfNotification.humanReadable[alertTitle] ?? alertTitle
            title = title.replacingOccurrences(of: "{{certType}}", with: certType)
        default: break
        }

        let params = raw["params"] as? [String: Any] ?? [:]
        for (k, v) in params {
            title = title.replacingOccurrences(of: "{{\(k)}}", with: "\(v)")
        }

        self.displayTitle = title
        self.key          = titleKey
    }
}

// MARK: - InstanceStatus

/// Latest polled state for a single Jamf Pro instance.
struct InstanceStatus {
    var connection: MonitorViewModel.ConnectionStatus = .unknown
    var authMessage: String = ""
    var notifications: [ParsedNotification] = []
    var healthStatus: HealthStatus?
}

// MARK: - MonitorViewModel

@MainActor
final class MonitorViewModel: ObservableObject {

    @Published var menuBarIconName: String = "cloudStatus-green"
    @Published private(set) var instances: [JamfInstance] = []
    @Published private(set) var statuses: [UUID: InstanceStatus] = [:]

    enum ConnectionStatus { case unknown, connected, failed }

    private var prevState: String = "cloudStatus-green"
    private var monitorTask: Task<Void, Never>?
    private var alertPanel: StatusAlertPanel?

    /// Credentials for each instance, loaded from the keychain once and kept in memory.
    private var credentials: [UUID: (username: String, password: String)] = [:]

    private let fm = FileManager.default
    private let launchAgentPath = NSHomeDirectory() + "/Library/LaunchAgents/com.jamf.cloudmonitor.plist"

    init() {
        if UserDefaults.standard.object(forKey: "pollingInterval") == nil {
            UserDefaults.standard.set(300, forKey: "pollingInterval")
        }
        if UserDefaults.standard.object(forKey: "hideUntilStatusChange") == nil {
            UserDefaults.standard.set(true, forKey: "hideUntilStatusChange")
        }
        if UserDefaults.standard.object(forKey: "hideMenubarIcon") == nil {
            UserDefaults.standard.set(false, forKey: "hideMenubarIcon")
        }
        if UserDefaults.standard.object(forKey: "launchAgent") == nil {
            UserDefaults.standard.set(false, forKey: "launchAgent")
        }

        let os = ProcessInfo().operatingSystemVersion
        writeToLog.message(stringOfText: [""])
        writeToLog.message(stringOfText: ["================================================================"])
        writeToLog.message(stringOfText: ["    \(AppInfo.displayname) Version: \(AppInfo.version) build: \(AppInfo.build)"])
        writeToLog.message(stringOfText: ["         macOS Version: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"])
        writeToLog.message(stringOfText: ["================================================================"])

        instances = JamfInstanceStore.load()
        if instances.isEmpty {
            writeToLog.message(stringOfText: ["[Auth] No Jamf Pro instances configured"])
        }
        for instance in instances {
            loadCredentials(for: instance)
        }

        startMonitoring()
    }

    // MARK: - Instance state

    func status(for instanceId: UUID) -> InstanceStatus {
        statuses[instanceId] ?? InstanceStatus()
    }

    var totalNotificationCount: Int {
        instances.reduce(0) { $0 + status(for: $1.id).notifications.count }
    }

    // MARK: - Monitor loop

    func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let interval = max(
                    UserDefaults.standard.integer(forKey: "pollingInterval"), 60
                )
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    private func tick() async {
        // Poll every instance concurrently; network waits don't block the main actor.
        await withTaskGroup(of: Void.self) { group in
            for instance in instances {
                group.addTask { await self.refresh(instance) }
            }
        }
        let iconResult = (try? await getCloudStatus()) ?? "cloudStatus-green"
        updateMenuBarIcon(for: iconResult)
    }

    private func refresh(_ instance: JamfInstance) async {
        Logger.check.info("checking server: \(instance.url, privacy: .public)")

        guard let creds = credentials[instance.id] else {
            setStatus(InstanceStatus(connection: .failed, authMessage: "No credentials saved"), for: instance.id)
            return
        }

        let token = await TokenManager.shared.validToken(
            for: instance,
            username: creds.username.lowercased(),
            password: creds.password
        )
        guard token.authMessage == "success" else {
            setStatus(InstanceStatus(connection: .failed, authMessage: token.authMessage), for: instance.id)
            return
        }

        var newStatus = InstanceStatus(connection: .connected, authMessage: "success")
        newStatus.notifications = await fetchNotifications(instance, token: token.token)
        newStatus.healthStatus  = await fetchHealthStatus(instance, token: token.token)
        setStatus(newStatus, for: instance.id)
    }

    private func setStatus(_ status: InstanceStatus, for instanceId: UUID) {
        // Ignore results for an instance that was removed while it was being polled
        guard instances.contains(where: { $0.id == instanceId }) else { return }
        statuses[instanceId] = status
    }

    // MARK: - Notifications

    private func fetchNotifications(_ instance: JamfInstance, token: String) async -> [ParsedNotification] {
        do {
            let alerts = try await UapiCall().get(serverUrl: instance.url, token: token, endpoint: "v1/notifications")
            return alerts.compactMap { ParsedNotification(raw: $0) }
        } catch UapiError.unauthorized {
            await TokenManager.shared.invalidate(instance.id)
        } catch {
            Logger.jpapi.info("[\(instance.displayName, privacy: .public)] notifications request failed: \(error.localizedDescription, privacy: .public)")
        }
        return []
    }

    // MARK: - Cloud status

    private func getCloudStatus() async throws -> String {
        // Debug override: load from local file instead of network
        let data: Data
        if let testPath = UserDefaults.standard.string(forKey: "debugCloudStatusFile") {
            guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: testPath)) else {
                return "cloudStatus-green"
            }
            data = fileData
        } else {
            // Only check Jamf Cloud status once at least one instance is reachable
            guard statuses.values.contains(where: { $0.connection == .connected }) else {
                return "cloudStatus-green"
            }

            let apiUrl = "\(Preferences.baseUrl)/api/v2/components.json"
            guard let url = URL(string: apiUrl) else { return "cloudStatus-green" }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let config = URLSessionConfiguration.default
            config.httpAdditionalHeaders = [
                "Accept": "application/json",
                "User-Agent": AppInfo.userAgentHeader
            ]
            let session = URLSession(configuration: config)
            let (networkData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw HealthStatusError.invalidResponse
            }
            data = networkData
        }

        var operational = [String](), warning = [String](), critical = [String]()
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let components = json["components"] as? [[String: Any]] {
            for c in components {
                guard let name   = c["name"]   as? String,
                      let status = c["status"] as? String else { continue }
                switch status {
                case "major_outage":          critical.append("\(name): Major Outage")
                case "partial_outage":        warning.append("\(name): Partial Outage")
                case "degraded_performance":  warning.append("\(name): Degraded Performance")
                default:                      operational.append("\(name): Operational")
                }
            }
        }

        let hideUntilChange = UserDefaults.standard.bool(forKey: "hideUntilStatusChange")

        if !critical.isEmpty {
            let body = critical.map { "    \($0)" }.joined(separator: "\n")
            maybeShowAlert(
                header: "Jamf Cloud Critical Issue Alert",
                message: "Please be aware there is a major issue that may affect your Jamf Cloud instance.\n\(body)",
                state: "cloudStatus-red",
                hideUntilChange: hideUntilChange
            )
            return "cloudStatus-red"
        } else if !warning.isEmpty {
            let body = warning.map { "    \($0)" }.joined(separator: "\n")
            maybeShowAlert(
                header: "Jamf Cloud Minor Issue Alert",
                message: "Please be aware there is a minor issue that may affect your Jamf Cloud instance.\n\(body)",
                state: "cloudStatus-yellow",
                hideUntilChange: hideUntilChange
            )
            return "cloudStatus-yellow"
        } else {
            maybeShowAlert(
                header: "Notice",
                message: "\nJamf Cloud: All systems go.",
                state: "cloudStatus-green",
                hideUntilChange: hideUntilChange
            )
            return "cloudStatus-green"
        }
    }

    private func maybeShowAlert(header: String, message: String, state: String, hideUntilChange: Bool) {
        let stateChanged = prevState != state
        let shouldShow   = stateChanged || (!hideUntilChange && prevState != "cloudStatus-green")
        if shouldShow {
            writeToLog.message(stringOfText: ["[Alert] \(header): \(message)"])
            alertPanel?.orderOut(nil)
            alertPanel = StatusAlertPanel(header: header, message: message, alertState: state)
            alertPanel?.showOnActiveScreen()
        }
        prevState = state
    }

    private func updateMenuBarIcon(for result: String) {
        let style = UserDefaults.standard.string(forKey: "menuIconStyle") ?? "color"
        if style == "color" || result == "cloudStatus-green" {
            menuBarIconName = result
        } else {
            menuBarIconName = result == "cloudStatus-yellow" ? "cloudStatus-yellow1" : "cloudStatus-red1"
        }
    }

    // MARK: - Health status

    private func fetchHealthStatus(_ instance: JamfInstance, token: String) async -> HealthStatus? {
        guard let url = URL(string: "\(instance.url)/api/v1/health-status") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod  = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgentHeader, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HealthStatusError.invalidResponse }
            if http.statusCode == 401 {
                await TokenManager.shared.invalidate(instance.id)
                throw HealthStatusError.authenticationFailed
            }
            guard (200..<300).contains(http.statusCode) else { throw HealthStatusError.invalidResponse }

            let decoded = try JSONDecoder().decode(HealthStatus.self, from: data)
            Logger.check.info("[\(instance.displayName, privacy: .public)] health status updated")
            logHealthRateWarnings(decoded, instance: instance)
            return decoded
        } catch {
            Logger.check.info("[\(instance.displayName, privacy: .public)] health status request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func logHealthRateWarnings(_ hs: HealthStatus, instance: JamfInstance) {
        for (label, api) in [("API", hs.api), ("UI", hs.ui), ("Enrollment", hs.enrollment),
                              ("Device", hs.device), ("Default", hs.healthStatusDefault)] {
            let mirror = Mirror(reflecting: api)
            let low = mirror.children.compactMap { child -> String? in
                guard let name = child.label, let rate = child.value as? Double, rate < 1.0 else { return nil }
                return "    \(name): \(rate)"
            }
            if !low.isEmpty {
                writeToLog.message(stringOfText: ["[\(instance.displayName)] \(label) rate warning:"] + low)
            }
        }
    }

    // MARK: - Instance management

    private func loadCredentials(for instance: JamfInstance) {
        let creds = Credentials().itemLookup(service: instance.url.fqdn, useApiClient: instance.useApiClient)
        if creds.count == 2 {
            credentials[instance.id] = (creds[0], creds[1])
            writeToLog.message(stringOfText: ["[Auth] Credentials loaded from keychain for \(instance.url.fqdn), auth mode: \(instance.useApiClient ? "API client" : "username/password")"])
        } else {
            credentials[instance.id] = nil
            writeToLog.message(stringOfText: ["[Auth] No credentials found in keychain for \(instance.url.fqdn)"])
        }
    }

    /// Credentials currently in use for a configured instance.
    func savedCredentials(for instanceId: UUID) -> (username: String, password: String)? {
        credentials[instanceId]
    }

    /// Credentials stored in the keychain for a server and auth type, used to prefill Settings.
    func storedCredentials(url: String, useApiClient: Bool) -> (username: String, password: String)? {
        guard !url.isEmpty else { return nil }
        let creds = Credentials().itemLookup(service: url.fqdn, useApiClient: useApiClient)
        return creds.count == 2 ? (creds[0], creds[1]) : nil
    }

    /// Verifies the credentials by requesting a token, then adds or updates the instance.
    /// Returns nil on success, otherwise a message describing the failure.
    func saveInstance(_ instance: JamfInstance, username: String, password: String) async -> String? {
        guard !instance.url.isEmpty, !username.isEmpty, !password.isEmpty else {
            return "Server URL, username, and password are required."
        }
        if instances.contains(where: { $0.id != instance.id && $0.url.fqdn == instance.url.fqdn && $0.useApiClient == instance.useApiClient }) {
            return "\(instance.url.fqdn) is already configured with this authentication type."
        }

        let token = await TokenManager.shared.requestToken(for: instance, username: username.lowercased(), password: password)
        guard token.authMessage == "success" else {
            await TokenManager.shared.invalidate(instance.id)
            return token.authMessage
        }

        let previous = instances.first(where: { $0.id == instance.id })
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[index] = instance
        } else {
            instances.append(instance)
        }
        JamfInstanceStore.save(instances)

        Credentials().save(service: instance.url.fqdn, account: username, data: password, useApiClient: instance.useApiClient)
        credentials[instance.id] = (username, password)
        if let previous, previous.url.fqdn != instance.url.fqdn || previous.useApiClient != instance.useApiClient {
            deleteCredentialsIfUnused(previous)
        }

        statuses[instance.id] = InstanceStatus(connection: .connected, authMessage: "success")
        writeToLog.message(stringOfText: ["[Auth] Settings saved — token granted for \(instance.url)"])

        Task { await refresh(instance) }
        return nil
    }

    func removeInstance(id: UUID) {
        guard let index = instances.firstIndex(where: { $0.id == id }) else { return }
        let removed = instances.remove(at: index)
        JamfInstanceStore.save(instances)
        statuses[id] = nil
        credentials[id] = nil
        deleteCredentialsIfUnused(removed)
        Task { await TokenManager.shared.invalidate(id) }
        writeToLog.message(stringOfText: ["[Settings] Removed instance \(removed.url)"])
    }

    /// Keychain entries are keyed by server and auth type, so only delete when no other instance shares them.
    private func deleteCredentialsIfUnused(_ instance: JamfInstance) {
        let stillUsed = instances.contains { $0.url.fqdn == instance.url.fqdn && $0.useApiClient == instance.useApiClient }
        if !stillUsed {
            Credentials().delete(service: instance.url.fqdn, useApiClient: instance.useApiClient)
        }
    }

    // MARK: - LaunchAgent

    func applyLaunchAgent(_ enable: Bool) {
        if enable {
            guard !fm.fileExists(atPath: launchAgentPath) else { return }
            let dir = NSHomeDirectory() + "/Library/LaunchAgents"
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            let src = Bundle.main.bundlePath + "/Contents/Resources/com.jamf.cloudmonitor.plist"
            try? fm.copyItem(atPath: src, toPath: launchAgentPath)
        } else {
            if fm.fileExists(atPath: launchAgentPath) {
                try? fm.removeItem(atPath: launchAgentPath)
            }
        }
    }
}
