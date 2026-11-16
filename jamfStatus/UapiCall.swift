//
//  UapiCall.swift
//

// get notifications from https://jamf.pro.server/uapi/notifications/alerts - old
// get notifications from https://jamf.pro.server/api/v1/notifications


import Foundation
import OSLog

enum UapiError: Error {
    case unauthorized
    case requestFailed
}

class UapiCall: NSObject, URLSessionDelegate {
    
    /// Fetches a Jamf Pro API endpoint that returns an array of objects (e.g. v1/notifications).
    /// Throws `UapiError.unauthorized` on a 401 so the caller can discard the token.
    func get(serverUrl: String, token: String, endpoint: String) async throws -> [[String: Any]] {
        
        var workingUrlString = "\(serverUrl)/api/\(endpoint)"
        workingUrlString     = workingUrlString.replacingOccurrences(of: "//api", with: "/api")
        guard let url = URL(string: workingUrlString) else { throw UapiError.requestFailed }
        
        var request = URLRequest(url: url)
        request.httpMethod  = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["Authorization" : "Bearer \(token)", "Content-Type" : "application/json", "Accept" : "application/json", "User-Agent" : AppInfo.userAgentHeader]
        
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw UapiError.requestFailed }
        
        guard httpResponse.statusCode >= 200 && httpResponse.statusCode <= 299 else {
            Logger.jpapi.debug("\(endpoint, privacy: .public) - get response error: \(httpResponse.statusCode, privacy: .public)")
            if httpResponse.statusCode == 401 { throw UapiError.unauthorized }
            throw UapiError.requestFailed
        }
        
        let json = try JSONSerialization.jsonObject(with: data, options: .allowFragments)
        guard let notificationsDictArray = json as? [[String: Any]] else {
            Logger.jpapi.info("An error creating notifications array")
            let dataString = String(data: data, encoding: .utf8) ?? "No data"
            Logger.jpapi.info("returned data: \(dataString, privacy: .public)")
            return []
        }
        return notificationsDictArray
    }   // func get - end
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping(  URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
    
}
