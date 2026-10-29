//
//  RemoteAuthService.swift
//  Node
//
//  Core/Auth/RemoteAuthService.swift
//

import Foundation

// MARK: - Server address handling

enum ServerConfig {

    private static let key = "serverURL"

    /// The last server the user connected to (not a secret, so UserDefaults is fine).
    static var savedURL: String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    static func save(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: key)
    }

    /// Cleans user input into a usable base URL, or returns nil.
    /// - adds https:// if the user left it off
    /// - REFUSES plain http:// because passwords and tokens must never travel unencrypted
    static func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}

// MARK: - Real server implementation

struct RemoteAuthService: AuthService {

    let baseURL: URL

    func signIn(email: String, password: String) async throws -> AuthSession {
        try await send("auth/login", body: ["email": email, "password": password])
    }

    func register(email: String, password: String, inviteCode: String) async throws -> AuthSession {
        try await send("auth/register", body: [
            "email": email,
            "password": password,
            "invite_code": inviteCode
        ])
    }

    // MARK: Private

    private struct TokenResponse: Decodable {
        let token: String
        let userName: String
        enum CodingKeys: String, CodingKey {
            case token
            case userName = "user_name"
        }
    }

    private struct ErrorResponse: Decodable {
        let detail: String
    }

    private func send(_ path: String, body: [String: String]) async throws -> AuthSession {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await ServerTrust.session.data(for: request)
        } catch {
            // A self-signed or changed certificate: let the UI show the fingerprint and ask.
            if let host = baseURL.host,
               let fingerprint = ServerTrust.takeRejectedFingerprint(for: host) {
                throw AuthError.untrustedCertificate(host: host, fingerprint: fingerprint)
            }
            throw AuthError.network          // DNS failure, refused, timeout...
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.network }

        let serverMessage = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.detail

        switch http.statusCode {
        case 200...299:
            guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                throw AuthError.server(http.statusCode)
            }
            return AuthSession(accessToken: decoded.token, userName: decoded.userName)
        case 400, 422:
            throw AuthError.validation(serverMessage ?? "Please check what you entered.")
        case 401:
            throw AuthError.invalidCredentials
        case 403:
            throw AuthError.rejected(serverMessage ?? "The server refused this request.")
        case 409:
            throw AuthError.accountExists
        case 429:
            throw AuthError.tooManyAttempts(serverMessage ?? "Too many attempts. Try again later.")
        default:
            throw AuthError.server(http.statusCode)
        }
    }
}
