//
//  ServerTrust.swift
//  Node
//
//  Core/Auth/ServerTrust.swift
//  Lets Node talk to a self-hosted server that uses a self-signed certificate,
//  but only after the user has explicitly approved that exact certificate.
//
//  How it works
//  1. A normal (CA-signed) certificate is validated by the system as usual.
//  2. If the system rejects the certificate, we compare its SHA-256 fingerprint
//     with the one the user previously approved for that host.
//  3. No match -> the request is cancelled and the fingerprint is remembered so
//     the UI can show it and ask "Trust this server?".
//  4. If the user approves, the fingerprint is stored and the request is retried.
//  If the server's certificate ever changes, the fingerprint no longer matches
//  and the user is asked again.
//

import Foundation
import CryptoKit
import Security

nonisolated enum ServerTrust {

    // MARK: Session

    /// Use this instead of `URLSession.shared` for every request to the user's server.
    static let session: URLSession = {
        URLSession(configuration: .default, delegate: TrustDelegate(), delegateQueue: nil)
    }()

    // MARK: Pinned fingerprints (not secret, so UserDefaults is fine)

    private static let defaultsKey = "trustedServerCertificates"
    private static let lock = NSLock()
    private static var rejected: [String: String] = [:]     // host -> fingerprint of last refused cert

    static func pinnedFingerprint(for host: String) -> String? {
        let all = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]
        return all?[host.lowercased()]
    }

    static func pin(_ fingerprint: String, for host: String) {
        var all = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        all[host.lowercased()] = fingerprint
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    static func removePin(for host: String) {
        var all = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        all[host.lowercased()] = nil
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    // MARK: Rejections (so the UI can ask the user)

    fileprivate static func recordRejection(host: String, fingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        rejected[host.lowercased()] = fingerprint
    }

    /// Returns (and clears) the fingerprint of the certificate that was just refused for `host`.
    static func takeRejectedFingerprint(for host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return rejected.removeValue(forKey: host.lowercased())
    }

    // MARK: Helpers

    /// SHA-256 of the leaf certificate, e.g. "AB:CD:...".
    static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

nonisolated private final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 1. Certificates the system already trusts need nothing special.
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 2. Otherwise accept only a certificate the user approved for this host.
        let host = challenge.protectionSpace.host
        guard let fingerprint = ServerTrust.fingerprint(of: trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if ServerTrust.pinnedFingerprint(for: host) == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            ServerTrust.recordRejection(host: host, fingerprint: fingerprint)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
