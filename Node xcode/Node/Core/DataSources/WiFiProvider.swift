//
//  WiFiProvider.swift
//  Node
//
//  Name (SSID) of the current Wi-Fi network. iOS only.
//
//  Apple requires BOTH:
//    • the "Access Wi-Fi Information" capability
//        (Xcode → Signing & Capabilities → + Capability), and
//    • Location permission (When In Use).
//  Without the capability fetchCurrent() quietly returns nil, so this simply reports nothing.
//

import Foundation
#if os(iOS)
import NetworkExtension
#endif

enum WiFiProvider {

    /// Wi-Fi name has no prompt of its own: it rides on Location permission.
    static func status(location: PermissionState) -> PermissionState {
        #if os(iOS)
        return location
        #else
        return .unavailable
        #endif
    }

    static func read(location: PermissionState) async -> SourcesInfo.WiFiInfo? {
        #if os(iOS)
        guard location == .granted else { return nil }
        guard let network = await NEHotspotNetwork.fetchCurrent() else { return nil }
        let ssid = network.ssid
        return ssid.isEmpty ? nil : .init(ssid: ssid)
        #else
        return nil
        #endif
    }
}
