//
//  AppState.swift
//  MyApp
//
//  Created by Veerjyot Singh on 27/09/26.
//

import SwiftUI
import Combine

final class AppState: ObservableObject {

    // MARK: - Auth
    @Published var isAuthenticated = false      // a valid session exists
    @Published var isLocked = false             // session exists but needs PIN/biometrics
    @Published var needsPINSetup = false
    @Published var currentUserName = ""

    @Published var biometricsEnabled = false

    // MARK: - UI
    @Published var selectedTab: Tab = .chat

    enum Tab: String, CaseIterable { // CaseIterable gives Tab.allCases = [.chat, .devices, .core, .account]
        case chat, devices, core, account

        var title: String { //this allows Tab.chat.title which returns the string Chat
            switch self {
            case .chat:       return "Chat"
            case .devices:    return "Devices"
            case .core: return "Core"
            case .account:    return "Account"
            }
        }

        var icon: String { //this allows Tab.chat.icon which return the string bubble.left...
            switch self {
            case .chat:       return "bubble.left.and.bubble.right.fill"
            case .devices:    return "network"
            case .core: return "cpu"
            case .account:    return "person.crop.circle.fill"
            }
        }
    }

    private let keychain = KeychainManager.shared //creates a reference to your shared KeychainManager

    init() {
        biometricsEnabled = UserDefaults.standard.bool(forKey: "biometricsEnabled") // Load the enabled setting for Biometric Auth at start up
        restoreSession()
    }
    
    func setBiometricsEnabled(_ enabled: Bool) {
        biometricsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "biometricsEnabled") // Store the enabled setting for Biometric Auth
    }

    // MARK: - Session

    private func restoreSession() {
        guard let token = keychain.loadString(KeychainKey.accessToken), !token.isEmpty else { return }
        currentUserName = keychain.loadString(KeychainKey.userName) ?? ""
        isAuthenticated = true
        let hasPIN = PINManager.shared.isPINSet
        isLocked = hasPIN               // cold launch requires unlock
        needsPINSetup = !hasPIN
    }

    func completeSignIn(_ session: AuthSession) throws {
        try keychain.saveString(session.accessToken, for: KeychainKey.accessToken) //Save for Access Token in Keychain
        try keychain.saveString(session.userName, for: KeychainKey.userName) //Save for the Username in Keychain
        currentUserName = session.userName
        isAuthenticated = true
        isLocked = false
        needsPINSetup = !PINManager.shared.isPINSet //Checks if there is a pin in the PIN Manager
    }

    func lock() {
        if isAuthenticated && PINManager.shared.isPINSet { isLocked = true }
    }

    func unlock() { isLocked = false }

    func signOut() {
        keychain.delete(KeychainKey.accessToken)
        keychain.delete(KeychainKey.userName)
        PINManager.shared.removePIN()
        biometricsEnabled = false
        currentUserName = ""
        isAuthenticated = false
        isLocked = false
        needsPINSetup = false
    }
}
