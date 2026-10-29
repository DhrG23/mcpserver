//
//  ContactsProvider.swift
//  Node
//
//  Reads ONLY the number of contacts. Names, numbers and emails are never fetched.
//

import Foundation
import Contacts

enum ContactsProvider {

    static func status() -> PermissionState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:    return .granted
        case .limited:       return .limited
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    static func request() async -> PermissionState {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        return status()
    }

    static func read() async -> SourcesInfo.ContactsInfo? {
        guard status().allowsReading else { return nil }
        let count = await Task.detached(priority: .utility) {
            ContactsProvider.countContacts()
        }.value
        return .init(count: count)
    }

    // Enumerating is synchronous and can be slow, so it runs off the main thread.
    nonisolated private static func countContacts() -> Int {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        var total = 0
        try? store.enumerateContacts(with: request) { _, _ in total += 1 }
        return total
    }
}
