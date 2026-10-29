//
//  KeychainKey.swift
//  Node
//
//  Created by Veerjyot Singh on 28/09/26.
//
//  Keychain wrapper. Changes in this version:
//  • KeychainError now says WHICH keychain error happened (the old one printed
//    "Node.KeychainError error 0" and hid the real code).
//  • On macOS, if the modern "data protection" keychain isn't available to this build
//    (error -34018, happens when the app isn't signed with a Team), it falls back to the
//    classic keychain instead of failing sign-up.
//

import Foundation
import Security

enum KeychainKey {
    static let accessToken = "accessToken"
    static let userName    = "userName"
    static let pinHash     = "pinHash"
    static let pinSalt     = "pinSalt"
    static let pinFailures = "pinFailures"
}

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let system = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            var text = "Couldn't save your session securely (Keychain error \(status): \(system))."
            if status == errSecMissingEntitlement {
                text += " In Xcode, open the Node target → Signing & Capabilities and choose a Team."
            }
            return text
        }
    }
}

final class KeychainManager {
    static let shared = KeychainManager()
    private init() {}

    private let service = Bundle.main.bundleIdentifier ?? "com.veerjyotsingh.Node"

    // MARK: Save / load / delete

    func save(_ data: Data, for key: String) throws {
        var status = add(data, for: key, dataProtection: true)
        #if os(macOS)
        if status == errSecMissingEntitlement {                 // -34018: not signed with a Team
            status = add(data, for: key, dataProtection: false)
        }
        #endif
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func load(_ key: String) -> Data? {
        if let data = read(key, dataProtection: true) { return data }
        #if os(macOS)
        return read(key, dataProtection: false)
        #else
        return nil
        #endif
    }

    func delete(_ key: String) {
        SecItemDelete(baseQuery(for: key, dataProtection: true) as CFDictionary)
        #if os(macOS)
        SecItemDelete(baseQuery(for: key, dataProtection: false) as CFDictionary)
        #endif
    }

    // MARK: Convenience for strings

    func saveString(_ value: String, for key: String) throws {
        try save(Data(value.utf8), for: key)
    }

    func loadString(_ key: String) -> String? {
        load(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Plumbing

    private func add(_ data: Data, for key: String, dataProtection: Bool) -> OSStatus {
        let query = baseQuery(for: key, dataProtection: dataProtection)
        SecItemDelete(query as CFDictionary)                    // replace any existing value
        var attributes = query
        attributes[kSecValueData as String] = data
        if dataProtection {                                     // not supported by the classic macOS keychain
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func read(_ key: String, dataProtection: Bool) -> Data? {
        var query = baseQuery(for: key, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    private func baseQuery(for key: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        #if os(macOS)
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query                                            // iOS always uses the data protection keychain
    }
}
