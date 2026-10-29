//
//  ScreenTimeProvider.swift
//  Node
//
//  Screen Time authorization (FamilyControls), iOS only.
//
//  What Apple allows: the app can ask the user to approve Screen Time access and can
//  shield/limit apps. It can NOT read usage numbers: those are only visible inside a
//  separate DeviceActivityReport extension and are deliberately kept from the app and
//  from your server. So Node reports just whether access is approved.
//
//  Needs the Family Controls capability, which Apple must approve for your App ID
//  (request it at developer.apple.com). Compiled out until you opt in:
//    Build Settings → "Active Compilation Conditions" → add  FAMILYCONTROLS_ENABLED
//

import Foundation
#if os(iOS) && FAMILYCONTROLS_ENABLED
import FamilyControls
#endif

enum ScreenTimeProvider {

    static func status() -> PermissionState {
        #if os(iOS) && FAMILYCONTROLS_ENABLED
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approved:      return .granted
        case .denied:        return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
        #else
        return .unavailable
        #endif
    }

    static func request() async -> PermissionState {
        #if os(iOS) && FAMILYCONTROLS_ENABLED
        try? await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        return status()
        #else
        return .unavailable
        #endif
    }
}
