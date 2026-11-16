//
//  TokenManager.swift
//

import Foundation
import OSLog

actor TokenManager {
    static let shared = TokenManager()
    
    /// Most recent token for each Jamf Pro instance, keyed by instance id.
    private var tokens: [UUID: TokenInfo] = [:]
    
    /// Returns a usable token for the instance, requesting a new one if none is cached
    /// or the cached token is about to expire.
    func validToken(for instance: JamfInstance, username: String, password: String) async -> TokenInfo {
        if let cached = tokens[instance.id], cached.authMessage == "success", !cached.renewToken {
            return cached
        }
        return await requestToken(for: instance, username: username, password: password)
    }
    
    /// Discards the cached token, e.g. after a 401 or when the instance's settings change.
    func invalidate(_ instanceId: UUID) {
        tokens[instanceId] = nil
    }

    @discardableResult
    func requestToken(for instance: JamfInstance, username: String, password: String) async -> TokenInfo {
        let tokenInfo = await fetchToken(serverUrl: instance.url, useApiClient: instance.useApiClient, username: username, password: password)
        tokenInfo.id = instance.id
        tokens[instance.id] = tokenInfo
        return tokenInfo
    }

    private func fetchToken(serverUrl: String, useApiClient: Bool, username: String, password: String) async -> TokenInfo {
        
let newTokenInfo: TokenInfo
        
        let tokenUrlString = !useApiClient ? "\(serverUrl)/api/v1/auth/token" : "\(serverUrl)/api/oauth/token"
        Logger.check.debug("request token from: \(tokenUrlString, privacy: .public)")
        
        guard let tokenUrl = URL(string: tokenUrlString) else {
            writeToLog.message(stringOfText: ["[Auth] Invalid token URL: \(tokenUrlString)"])
            newTokenInfo = TokenInfo(url: serverUrl, token: "", expiresAt: Date(), authMessage: "Invalid URL: \(tokenUrlString)")
            return newTokenInfo
        }

        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "POST"

        if !useApiClient {
            let base64creds = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(base64creds)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else {
            let clientString = "grant_type=client_credentials&client_id=\(username)&client_secret=\(password)"
            let requestData = clientString.data(using: .utf8)
            request.httpBody = requestData
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgentHeader, forHTTPHeaderField: "User-Agent")
        
        var authMessage = ""

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                switch statusCode {
                case 401:
                    authMessage = "\(401): Incorrect credentials"
                case 404:
                    authMessage = "\(404): Server not found"
                default:
                    let code = statusCode == -1 ? "Unknown error" : "\(statusCode)"
                    authMessage = "\(code): login failed"
                }
                Logger.check.debug("failed to get token: \(authMessage, privacy: .public)")
                writeToLog.message(stringOfText: ["[Auth] Token request failed for \(serverUrl): \(authMessage)"])
                newTokenInfo = TokenInfo(url: serverUrl, token: "", expiresAt: Date(), authMessage: authMessage)
                return newTokenInfo
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .formatted(DateFormatter.customISO8601)

            let tokenResponse = try decoder.decode(TokenResponse.self, from: data)

            switch tokenResponse {
            case .tokenData(let data):
                let token = data.token
                let expiration: Date
                
                if let _ = data.expires as? Date {
                    expiration = data.expires
                } else {
                    expiration = Date.now + 20 * 60
                }

                newTokenInfo = TokenInfo(url: serverUrl,
                                         token: token,
                                         expiresAt: expiration,
                                         authMessage: "success")

            case .accessTokenData(let data):
                newTokenInfo = TokenInfo(
                    url: serverUrl,
                    token: data.accessToken,
                    expiresAt: Date.now + data.expiresIn,
                    authMessage: "success"
                )
            }

            Logger.check.debug("granted new token for \(serverUrl, privacy: .public), expires \(newTokenInfo.expiresAt, privacy: .public)")
            return newTokenInfo

        } catch {
            Logger.check.debug("Token request failed: \(error.localizedDescription, privacy: .public)")
            writeToLog.message(stringOfText: ["[Auth] Token request error for \(serverUrl): \(error.localizedDescription)"])
            return TokenInfo(url: serverUrl, token: "", expiresAt: Date(), authMessage: error.localizedDescription)
        }
    }
}

