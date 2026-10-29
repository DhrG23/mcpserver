//
//  PhotosProvider.swift
//  Node
//
//  Photo library COUNTS only (photos, videos, screenshots, newest date).
//  No image is ever loaded or uploaded here.
//

import Foundation
import Photos

enum PhotosProvider {

    static func status() -> PermissionState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:    return .granted
        case .limited:       return .limited
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    static func request() async -> PermissionState {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status()
    }

    static func read() async -> SourcesInfo.PhotosInfo? {
        let current = status()
        guard current.allowsReading else { return nil }
        let limited = current == .limited
        return await Task.detached(priority: .utility) {
            PhotosProvider.stats(limited: limited)
        }.value
    }

    // PHAsset.fetchAssets is synchronous, so this runs off the main thread.
    nonisolated private static func stats(limited: Bool) -> SourcesInfo.PhotosInfo {
        let photos = PHAsset.fetchAssets(with: .image, options: nil).count
        let videos = PHAsset.fetchAssets(with: .video, options: nil).count

        let screenshotOptions = PHFetchOptions()
        screenshotOptions.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0",
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        let screenshots = PHAsset.fetchAssets(with: .image, options: screenshotOptions).count

        let newestOptions = PHFetchOptions()
        newestOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        newestOptions.fetchLimit = 1
        let newest = PHAsset.fetchAssets(with: newestOptions).firstObject?.creationDate

        return .init(photoCount: photos,
                     videoCount: videos,
                     screenshotCount: screenshots,
                     latestPhotoDate: newest,
                     isLimitedSelection: limited)
    }
}
