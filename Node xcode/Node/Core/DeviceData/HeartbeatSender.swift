//
//  HeartbeatSender.swift
//  Node
//
//  Core/DeviceData/HeartbeatSender.swift
//  How a DeviceSnapshot leaves the device. Swap implementations freely.
//

import Foundation

protocol HeartbeatSender: Sendable {
    func send(_ snapshot: DeviceSnapshot) async throws
}

enum HeartbeatError: LocalizedError {
    case noServer
    case notSignedIn
    case unauthorized
    case untrustedCertificate
    case server(Int)
    case network

    var errorDescription: String? {
        switch self {
        case .noServer:             return "No server address saved. Sign in first."
        case .notSignedIn:          return "You're not signed in."
        case .unauthorized:         return "The server rejected your session. Sign out and sign in again."
        case .untrustedCertificate: return "The server's certificate isn't trusted. Sign in again to review it."
        case .server(let code):     return "The server returned an unexpected error (\(code))."
        case .network:              return "Can't reach the server."
        }
    }
}

/// Prints the JSON to the Xcode console. Only for previews and offline development —
/// it never contacts a server, so it must not be used to report "connected".
struct LoggingHeartbeatSender: HeartbeatSender {
    func send(_ snapshot: DeviceSnapshot) async throws {
        print("── Heartbeat ──\n\(snapshot.jsonString())")
    }
}

/// POSTs the snapshot as JSON and succeeds only on a 2xx response.
///
/// DeviceMonitor builds this from `ServerConfig.savedURL` and the keychain token.
///
/// macOS note: "Outgoing Connections (Client)" must be enabled under
/// Signing & Capabilities → App Sandbox, or requests will fail.
struct HTTPHeartbeatSender: HeartbeatSender {

    /// Path appended to the saved server address. Change it if your API differs.
    static let path = "heartbeat"

    let endpoint: URL
    var token: String? = nil

    func send(_ snapshot: DeviceSnapshot) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try snapshot.jsonData()

        let response: URLResponse
        do {
            (_, response) = try await ServerTrust.session.data(for: request)
        } catch {
            if let host = endpoint.host,
               ServerTrust.takeRejectedFingerprint(for: host) != nil {
                throw HeartbeatError.untrustedCertificate
            }
            throw HeartbeatError.network
        }

        guard let http = response as? HTTPURLResponse else { throw HeartbeatError.network }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403:  throw HeartbeatError.unauthorized
        default:        throw HeartbeatError.server(http.statusCode)
        }
    }
}
