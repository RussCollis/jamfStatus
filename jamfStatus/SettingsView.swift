import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var monitor: MonitorViewModel

    @AppStorage("pollingInterval")       private var pollingInterval: Int    = 300
    @AppStorage("hideUntilStatusChange") private var hideUntilStatusChange: Bool = true
    @AppStorage("hideMenubarIcon")       private var hideMenubarIcon: Bool   = false
    @AppStorage("menuIconStyle")         private var menuIconStyle: String   = "color"
    @AppStorage("optOut")                private var optOut: Bool            = false

    // Instance currently being edited; nil while adding a new instance.
    @State private var selection: UUID?
    @State private var instanceName: String = ""
    @State private var serverUrl:    String = ""
    @State private var username:     String = ""
    @State private var password:     String = ""
    @State private var useApiClient: Bool   = false
    @State private var isSaving:     Bool   = false
    @State private var saveError:    String?
    @State private var confirmRemove: Bool  = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            serverTab
                .tabItem { Label("Server", systemImage: "server.rack") }

            analyticsTab
                .tabItem { Label("Analytics", systemImage: "chart.bar") }
        }
        .padding(20)
        .frame(width: 640, height: 440)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            loadCurrentValues()
        }
    }

    // MARK: - General tab

    private var generalTab: some View {
        Form {
            Section("Polling") {
                Stepper(value: $pollingInterval, in: 60...3600, step: 10) {
                    HStack {
                        Text("Interval (seconds):")
                        TextField("", value: $pollingInterval, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { clampPollingInterval() }
                    }
                }
            }

            Section("Menu Bar") {
                Toggle("Hide menubar icon", isOn: $hideMenubarIcon)
                Picker("Icon style:", selection: $menuIconStyle) {
                    Text("Color").tag("color")
                    Text("Slash").tag("slash")
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            Section("Alerts") {
                Toggle("Only alert when status changes", isOn: $hideUntilStatusChange)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Server tab

    private var serverTab: some View {
        HStack(spacing: 0) {
            instanceList
                .frame(width: 190)
            Divider()
            instanceEditor
        }
    }

    private var instanceList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(monitor.instances) { instance in
                    HStack(spacing: 6) {
                        connectionIndicator(monitor.status(for: instance.id).connection)
                        Text(instance.displayName)
                            .lineLimit(1)
                    }
                    .tag(instance.id)
                }
            }
            .onChange(of: selection) { _ in loadSelectedInstance() }

            HStack(spacing: 0) {
                Button { startNewInstance() } label: {
                    Image(systemName: "plus").frame(width: 24, height: 20)
                }
                .help("Add a Jamf Pro instance")

                Button { confirmRemove = true } label: {
                    Image(systemName: "minus").frame(width: 24, height: 20)
                }
                .disabled(selection == nil)
                .help("Remove the selected instance")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
        .alert("Remove Instance?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { removeSelectedInstance() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("jamfStatus will stop monitoring \(selectedInstance?.displayName ?? "this instance") and remove its saved credentials.")
        }
    }

    private var instanceEditor: some View {
        Form {
            Section("Authentication") {
                Picker("Type:", selection: $useApiClient) {
                    Text("Username / Password").tag(false)
                    Text("API Client").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: useApiClient) { _ in
                    loadStoredCredentials()
                }
            }

            Section {
                TextField("Name", text: $instanceName, prompt: Text("Optional, e.g. Production"))
                    .textFieldStyle(.roundedBorder)

                TextField(text: $serverUrl, prompt: Text("https://server.example.com")) {
                    EmptyView()
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit { validateAndSave() }

                TextField(useApiClient ? "Client ID" : "Username", text: $username)
                    .textFieldStyle(.roundedBorder)

                SecureField(useApiClient ? "Secret" : "Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            } header: {
                HStack(spacing: 6) {
                    if let selection {
                        connectionIndicator(monitor.status(for: selection).connection)
                    }
                    Text(selection == nil ? "New Jamf Pro Server" : "Jamf Pro Server")
                }
            }

            if let message = saveError ?? selectedStatusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if isSaving {
                    ProgressView().controlSize(.small)
                }
                Button(selection == nil ? "Add" : "Save") { validateAndSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
        }
        .formStyle(.grouped)
    }

    private func connectionIndicator(_ status: MonitorViewModel.ConnectionStatus) -> some View {
        Circle()
            .fill(status == .connected ? Color.green : Color.red)
            .frame(width: 10, height: 10)
    }

    // MARK: - Analytics tab

    private var analyticsTab: some View {
        Form {
            Section {
                Toggle("Opt out of analytics", isOn: $optOut)
                    .onChange(of: optOut) { newValue in
                        TelemetryDeckConfig.OptOut = newValue
                    }

                Text("By default, jamfStatus sends anonymous usage data to TelemetryDeck to help improve the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var selectedInstance: JamfInstance? {
        monitor.instances.first { $0.id == selection }
    }

    /// Last authentication error for the selected instance, if it is failing.
    private var selectedStatusMessage: String? {
        guard let selection else { return nil }
        let status = monitor.status(for: selection)
        return status.connection == .failed ? status.authMessage : nil
    }

    private func loadCurrentValues() {
        if selection == nil {
            selection = monitor.instances.first?.id
        }
        loadSelectedInstance()
    }

    private func loadSelectedInstance() {
        saveError = nil
        guard let instance = selectedInstance else {
            clearEditor()
            return
        }
        instanceName = instance.name
        serverUrl    = instance.url
        useApiClient = instance.useApiClient
        if let creds = monitor.savedCredentials(for: instance.id) {
            username = creds.username
            password = creds.password
        } else {
            loadStoredCredentials()
        }
    }

    private func loadStoredCredentials() {
        let stored = serverUrl.baseUrl
        if let creds = monitor.storedCredentials(url: stored, useApiClient: useApiClient) {
            username = creds.username
            password = creds.password
        } else {
            username = ""
            password = ""
        }
    }

    private func startNewInstance() {
        selection = nil
        clearEditor()
    }

    private func clearEditor() {
        instanceName = ""
        serverUrl    = ""
        username     = ""
        password     = ""
        useApiClient = false
        saveError    = nil
    }

    private func removeSelectedInstance() {
        guard let id = selection else { return }
        monitor.removeInstance(id: id)
        selection = monitor.instances.first?.id
        loadSelectedInstance()
    }

    private func clampPollingInterval() {
        if pollingInterval < 60 { pollingInterval = 300 }
    }

    private func validateAndSave() {
        let base = serverUrl.baseUrl
        guard !base.isEmpty else {
            saveError = "Enter a valid server URL, e.g. https://server.example.com"
            return
        }
        serverUrl = base

        var instance = selectedInstance ?? JamfInstance(name: "", url: base)
        instance.name         = instanceName.trimmingCharacters(in: .whitespaces)
        instance.url          = base
        instance.useApiClient = useApiClient

        isSaving  = true
        saveError = nil
        Task {
            let error = await monitor.saveInstance(instance, username: username, password: password)
            isSaving  = false
            saveError = error
            if error == nil {
                selection = instance.id
            }
        }
    }
}
