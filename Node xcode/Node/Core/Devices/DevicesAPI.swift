//
//  DevicesAPI.swift
//  Node
//
//  Talks to your server about the devices registered on it.
//
//  Endpoints this expects (all with  Authorization: Bearer <token>):
//    GET    /devices                  -> [device]   or   { "devices": [device] }
//    POST   /devices/{id}/commands    {"type":"notify","title":"…","body":"…"}
//    PATCH  /devices/{id}             {"name":"…"}
//    DELETE /devices/{id}
//  A 404/405 is reported as "your server doesn't have that endpoint yet".
//

import Foundation

enum DevicesError: LocalizedError {
    case noServer
    case notSignedIn
    case unauthorized
    case untrustedCertificate
    case network
    case endpointMissing(String)
    case server(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noServer:             return "No server address saved. Sign in first."
        case .notSignedIn:          return "You're not signed in."
        case .unauthorized:         return "The server rejected your session. Sign out and sign in again."
        case .untrustedCertificate: return "The server's certificate isn't trusted. Sign in again to review it."
        case .network:              return "Can't reach the server."
        case .endpointMissing(let e): return "Your server doesn't support \(e) yet."
        case .server(let code):     return "The server returned an unexpected error (\(code))."
        case .badResponse:          return "The server's device list wasn't in a format Node understands."
        }
    }
}

nonisolated private struct DeviceListWrapper: Decodable {
    let devices: [RemoteDevice]?
    let items: [RemoteDevice]?
    let data: [RemoteDevice]?
}

@MainActor
struct DevicesAPI {

    func list() async throws -> [RemoteDevice] {
        let data = try await perform("devices")
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode([RemoteDevice].self, from: data) { return direct }
        if let wrapped = try? decoder.decode(DeviceListWrapper.self, from: data),
           let list = wrapped.devices ?? wrapped.items ?? wrapped.data {
            return list
        }
        throw DevicesError.badResponse
    }

    func sendNotification(to id: String, title: String, body: String) async throws {
        try await perform("devices/\(id)/commands", method: "POST",
                          body: ["type": "notify", "title": title, "body": body])
    }

    func rename(_ id: String, to name: String) async throws {
        try await perform("devices/\(id)", method: "PATCH", body: ["name": name])
    }

    func remove(_ id: String) async throws {
        try await perform("devices/\(id)", method: "DELETE")
    }

    // MARK: Plumbing

    @discardableResult
    private func perform(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let base = ServerConfig.normalizedURL(ServerConfig.savedURL) else { throw DevicesError.noServer }
        guard let token = KeychainManager.shared.loadString(KeychainKey.accessToken), !token.isEmpty else {
            throw DevicesError.notSignedIn
        }

        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await ServerTrust.session.data(for: request)
        } catch {
            if let host = base.host, ServerTrust.takeRejectedFingerprint(for: host) != nil {
                throw DevicesError.untrustedCertificate
            }
            throw DevicesError.network
        }

        guard let http = response as? HTTPURLResponse else { throw DevicesError.network }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:  throw DevicesError.unauthorized
        case 404, 405:  throw DevicesError.endpointMissing("\(method) /\(path.split(separator: "/").first ?? "")")
        default:        throw DevicesError.server(http.statusCode)
        }
    }
}
