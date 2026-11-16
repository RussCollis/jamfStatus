//
//  Credentials.swift
//

import Foundation
import Security

let kSecAttrAccountString          = NSString(format: kSecAttrAccount)
let kSecValueDataString            = NSString(format: kSecValueData)
let kSecClassGenericPasswordString = NSString(format: kSecClassGenericPassword)
let keychainQ                      = DispatchQueue(label: "com.jamfie.jamfstatus", qos: DispatchQoS.background)

class Credentials {
    
    private func keychainService(_ service: String, useApiClient: Bool) -> String {
        return useApiClient ? "jamfStatus-apiClient: \(service)" : "jamfStatus: \(service)"
    }

    func save(service: String, account: String, data: String, useApiClient: Bool) {
        
        let theService = keychainService(service, useApiClient: useApiClient)
        
        keychainQ.async { [self] in
            if let password = data.data(using: String.Encoding.utf8) {
                var keychainQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                                    kSecAttrService as String: theService,
                                                    kSecAttrAccount as String: account,
                                                    kSecValueData as String: password]
                
                // see if credentials already exist for server
                let accountCheck = itemLookup(service: service, useApiClient: useApiClient)
                if accountCheck.count == 0 {
                    // try to add new credentials, if account exists we'll try updating it
                    let addStatus = SecItemAdd(keychainQuery as CFDictionary, nil)
                    if (addStatus != errSecSuccess) {
                        if let addErr = SecCopyErrorMessageString(addStatus, nil) {
                            print("[addStatus] Write failed for new credentials: \(addErr)")
                            let deleteStatus = SecItemDelete(keychainQuery as CFDictionary)
                            print("[Credentials.save] the deleteStatus: \(deleteStatus)")
                            sleep(1)
                            let addStatus = SecItemAdd(keychainQuery as CFDictionary, nil)
                            if (addStatus != errSecSuccess) {
                                if let addErr = SecCopyErrorMessageString(addStatus, nil) {
                                    print("[addStatus] Write failed for new credentials after deleting: \(addErr)")
                                }
                            }
                        }
                    }
                } else {
                    // credentials already exist, try to update
                    keychainQuery = [kSecClass as String: kSecClassGenericPasswordString,
                                     kSecAttrService as String: theService,
                                     kSecMatchLimit as String: kSecMatchLimitOne,
                                     kSecReturnAttributes as String: true]
                    let updateStatus = SecItemUpdate(keychainQuery as CFDictionary, [kSecAttrAccountString:account,kSecValueDataString:password] as CFDictionary)
                    if (updateStatus != errSecSuccess) {
                        if let updateErr = SecCopyErrorMessageString(updateStatus, nil) {
                            print("[updateStatus] Update failed for existing credentials: \(updateErr)")
                        }
                    }
                }
            }
        }
    }   // func save - end
    
    func itemLookup(service: String, useApiClient: Bool) -> [String] {
        var existingCredientials = retrieve(service: service, useApiClient: useApiClient)
        if existingCredientials.count == 0 {
            existingCredientials = retrieve(service: "\(service)/", useApiClient: useApiClient)
            if existingCredientials.count == 0 {
                existingCredientials = retrieve(service: "\(service):8443", useApiClient: useApiClient)
                if existingCredientials.count == 0 {
                    existingCredientials = retrieve(service: "\(service):8443/", useApiClient: useApiClient)
                }
            }
        }
        return existingCredientials
    }
    
    func retrieve(service: String, useApiClient: Bool) -> [String] {
        
        var storedCreds = [String]()
        
        let theService = keychainService(service, useApiClient: useApiClient)
        
        let keychainQuery: [String: Any] = [kSecClass as String: kSecClassGenericPasswordString,
                                            kSecAttrService as String: theService,
                                            kSecMatchLimit as String: kSecMatchLimitOne,
                                            kSecReturnAttributes as String: true,
                                            kSecReturnData as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(keychainQuery as CFDictionary, &item)
        guard status != errSecItemNotFound else { return [] }
        guard status == errSecSuccess else { return [] }
        
        guard let existingItem = item as? [String : Any],
            let passwordData = existingItem[kSecValueData as String] as? Data,
            let account = existingItem[kSecAttrAccount as String] as? String,
            let password = String(data: passwordData, encoding: String.Encoding.utf8)
        else {
            return []
        }
        
        storedCreds.append(account)
        storedCreds.append(password)
        return storedCreds
    }

    func delete(service: String, useApiClient: Bool) {
        let theService = keychainService(service, useApiClient: useApiClient)
        keychainQ.async {
            let keychainQuery: [String: Any] = [kSecClass as String: kSecClassGenericPasswordString,
                                                kSecAttrService as String: theService]
            let status = SecItemDelete(keychainQuery as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                if let deleteErr = SecCopyErrorMessageString(status, nil) {
                    print("[Credentials.delete] Delete failed: \(deleteErr)")
                }
            }
        }
    }
}
