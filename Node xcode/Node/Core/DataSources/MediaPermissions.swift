//
//  MediaPermissions.swift
//  Node
//
//  Camera and microphone. Node only asks for the permission and reports its state;
//  it never records, streams or uploads anything from either.
//

import Foundation
import AVFoundation

enum MediaPermissions {

    static func status(_ type: AVMediaType) -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    static func request(_ type: AVMediaType) async -> PermissionState {
        _ = await AVCaptureDevice.requestAccess(for: type)
        return status(type)
    }
}
