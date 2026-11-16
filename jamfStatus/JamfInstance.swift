//
//  JamfInstance.swift
//

import Foundation

// MARK: - JamfInstance

/// A single Jamf Pro server the app monitors. Credentials are kept in the keychain,
/// keyed by the server's FQDN and authentication type (see `Credentials`).
struct JamfInstance: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var useApiClient: Bool = false

    /// Name shown in the UI, falling back to the server's host name.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? url.fqdn : trimmed
    }
}

// MARK: - Persistence

enum JamfInstanceStore {
    private static let key = "jamfInstances"

    static func load() -> [JamfInstance] {
        if let data = UserDefaults.standard.data(forKey: key),
           let instances = try? JSONDecoder().decode([JamfInstance].self, from: data) {
            return instances
        }
        return migrateLegacyServer()
    }

    static func save(_ instances: [JamfInstance]) {
        guard let data = try? JSONEncoder().encode(instances) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Converts the single server configured by earlier versions (jamfServerUrl / useApiClient)
    /// into the first instance so existing users keep monitoring their server after upgrading.
    private static func migrateLegacyServer() -> [JamfInstance] {
        let legacyUrl = (UserDefaults.standard.string(forKey: "jamfServerUrl") ?? "").baseUrl
        guard !legacyUrl.isEmpty else { return [] }

        let instance = JamfInstance(
            name: legacyUrl.fqdn,
            url: legacyUrl,
            useApiClient: UserDefaults.standard.integer(forKey: "useApiClient") != 0
        )
        save([instance])
        writeToLog.message(stringOfText: ["[Settings] Migrated server \(legacyUrl) to multi-instance configuration"])
        return [instance]
    }
}
