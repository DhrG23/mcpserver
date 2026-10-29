//
//  PINManager.swift
//  Node
//
//  Created by Veerjyot Singh on 28/09/26.
//

import Foundation
import CommonCrypto
import Security

enum PINError: Error { case randomFailed, hashFailed }

final class PINManager {
    static let shared = PINManager()
    private init() {}

    static let pinLength = 6
    static let maxAttempts = 5
    private let keychain = KeychainManager.shared

    enum VerifyResult { case success, wrong(attemptsLeft: Int), lockedOut }

    var isPINSet: Bool { keychain.load(KeychainKey.pinHash) != nil }

    // Keeps only ASCII digits, capped at the PIN length
    static func sanitize(_ input: String) -> String {
        String(input.filter { $0.isASCII && $0.isNumber }.prefix(pinLength))
    }

    static func isWeak(_ pin: String) -> Bool {
        Set(pin).count == 1 || ["123456", "654321", "012345", "123123"].contains(pin)
    }

    func setPIN(_ pin: String) throws {
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess
        else { throw PINError.randomFailed }
        guard let hash = derive(pin: pin, salt: salt) else { throw PINError.hashFailed }
        try keychain.save(Data(salt), for: KeychainKey.pinSalt)
        try keychain.save(hash, for: KeychainKey.pinHash)
        failures = 0
    }

    func verify(_ pin: String) -> VerifyResult {
        guard failures < Self.maxAttempts else { return .lockedOut }
        guard let saltData = keychain.load(KeychainKey.pinSalt),
              let stored = keychain.load(KeychainKey.pinHash),
              let candidate = derive(pin: pin, salt: [UInt8](saltData))
        else { return .lockedOut }

        if constantTimeEqual(candidate, stored) {
            failures = 0
            return .success
        }
        failures += 1
        let left = Self.maxAttempts - failures
        return left > 0 ? .wrong(attemptsLeft: left) : .lockedOut
    }

    func removePIN() {
        keychain.delete(KeychainKey.pinHash)
        keychain.delete(KeychainKey.pinSalt)
        keychain.delete(KeychainKey.pinFailures)
    }

    // MARK: - Private

    private var failures: Int {
        get { keychain.loadString(KeychainKey.pinFailures).flatMap(Int.init) ?? 0 }
        set { try? keychain.saveString(String(newValue), for: KeychainKey.pinFailures) }
    }

    // PBKDF2-SHA256, 100k rounds: deliberately slow so brute-forcing is expensive
    private func derive(pin: String, salt: [UInt8]) -> Data? {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            pin, pin.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            100_000,
            &derived, derived.count
        )
        return status == kCCSuccess ? Data(derived) : nil
    }

    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
