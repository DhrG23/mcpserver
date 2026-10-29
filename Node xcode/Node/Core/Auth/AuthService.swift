//
//  AuthService.swift
//  Node
//
//  Core/Auth/AuthService.swift
//

import Foundation

struct AuthSession {
    let accessToken: String
    let userName: String
}

enum AuthError: LocalizedError {
    case invalidCredentials
    case network
    case accountExists
    case rejected(String)          // e.g. wrong invite code, registration disabled
    case tooManyAttempts(String)
    case invalidServerURL
    case validation(String)        // server said the input is unacceptable
    case server(Int)
    case untrustedCertificate(host: String, fingerprint: String)   // self-signed / changed certificate

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:      return "Incorrect email or password."
        case .network:                 return "Can't reach the server. Check the address and your connection."
        case .accountExists:           return "An account with this email already exists. Try signing in."
        case .rejected(let message):   return message
        case .tooManyAttempts(let m):  return m
        case .invalidServerURL:        return "Enter a valid server address, for example https://192.168.1.20:8443"
        case .validation(let message): return message
        case .server(let code):        return "The server returned an unexpected error (\(code))."
        case .untrustedCertificate:    return "This server's certificate isn't trusted yet."
        }
    }
}

protocol AuthService {
    func signIn(email: String, password: String) async throws -> AuthSession
    func register(email: String, password: String, inviteCode: String) async throws -> AuthSession
}

/// Development stand-in. Used only when LoginView.useMockServer is true.
struct MockAuthService: AuthService {

    func signIn(email: String, password: String) async throws -> AuthSession {
        try await Task.sleep(nanoseconds: 800_000_000)
        guard password.count >= 8 else { throw AuthError.invalidCredentials }
        return AuthSession(accessToken: UUID().uuidString, userName: name(from: email))
    }

    func register(email: String, password: String, inviteCode: String) async throws -> AuthSession {
        try await Task.sleep(nanoseconds: 800_000_000)
        guard !inviteCode.isEmpty else { throw AuthError.rejected("Invalid invite code.") }
        return AuthSession(accessToken: UUID().uuidString, userName: name(from: email))
    }

    private func name(from email: String) -> String {
        email.components(separatedBy: "@").first ?? email
    }
}
