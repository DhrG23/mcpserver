//
//  BiometricAuth.swift
//  Node
//
//  Created by Veerjyot Singh on 28/09/26.
//

import LocalAuthentication

enum BiometricKind {
    case faceID, touchID, none

    var name: String {
        switch self {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        case .none:    return "Biometrics"
        }
    }

    var icon: String {
        switch self {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        case .none:    return "lock"
        }
    }
}

enum BiometricAuth {

    static var availableKind: BiometricKind {
        let context = LAContext()
        var error: NSError?
        // biometryType is only filled in after canEvaluatePolicy runs
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        else { return .none }
        switch context.biometryType {
        case .faceID:  return .faceID
        case .touchID: return .touchID
        default:       return .none
        }
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = ""      // we provide our own PIN fallback
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            return false                          // cancelled or failed: user falls back to PIN
        }
    }
}
