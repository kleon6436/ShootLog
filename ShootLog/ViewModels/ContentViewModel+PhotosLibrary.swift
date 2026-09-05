import Foundation
import Photos
import SwiftData

@MainActor
extension ContentViewModel {
    func openPhotosLibrary() {
        Task {
            let service = PhotosLibraryPermissionService()
            let status = service.authorizationStatus()
            let resolvedStatus: PhotosLibraryPermissionStatus

            if status == .notDetermined {
                resolvedStatus = await service.requestAuthorization()
            } else {
                resolvedStatus = status
            }

            switch resolvedStatus {
            case .authorized:
                await loadPhotosLibraryPhotos()
            case .limited, .denied, .restricted, .notDetermined:
                isPhotosLibraryPermissionAlertPresented = true
            }
        }
    }

    func loadPhotosLibraryPhotos() async {
        guard let context = modelContext else { return }
        await cancelPhotoStaging()
        releaseBookmarkAccess()
        currentFolderURL = nil
        currentPhotoSource = .photosLibrary
        isLoading = true
        photos = []
        selectedPhoto = nil
        currentEditInfo = nil
        currentDevelopSettings = nil
        isCropMode = false

        let assets = await Task.detached(priority: .utility) {
            PhotosLibraryRepository.fetchAssets()
        }.value
        let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.shootlog.app/icloud-import-v1", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            self.error = error
            isLoading = false
            return
        }

        syncPhotosLibrary(assets: assets, cacheDirectory: cacheDirectory, context: context)
        selectPhoto(photos.first)
        isLoading = false
    }

    private func syncPhotosLibrary(
        assets: [PHAsset],
        cacheDirectory: URL,
        context: ModelContext
    ) {
        let all = (try? context.fetch(FetchDescriptor<Photo>())) ?? []
        let byIdentifier = Dictionary(
            all.compactMap { photo in
                photo.phAssetLocalIdentifier.map { ($0, photo) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let firstBatchCount = min(assets.count, Self.initialPhotoBatchSize)
        photos = assets[..<firstBatchCount].map {
            resolvePhotosLibraryPhoto(
                for: $0,
                cacheDirectory: cacheDirectory,
                existing: byIdentifier,
                context: context
            )
        }
        saveOrReportError(context)

        guard firstBatchCount < assets.count else { return }
        let remaining = Array(assets[firstBatchCount...])
        let generation = photoStagingGeneration
        photoStagingTask = Task {
            await stagePhotosLibraryPhotos(
                assets: remaining,
                cacheDirectory: cacheDirectory,
                existing: byIdentifier,
                context: context,
                generation: generation
            )
        }
    }

    private func stagePhotosLibraryPhotos(
        assets: [PHAsset],
        cacheDirectory: URL,
        existing byIdentifier: [String: Photo],
        context: ModelContext,
        generation: Int
    ) async {
        var index = 0
        while index < assets.count {
            guard !Task.isCancelled, generation == photoStagingGeneration else { return }
            let end = min(index + Self.photoStagingChunkSize, assets.count)
            let chunk = assets[index..<end].map {
                resolvePhotosLibraryPhoto(
                    for: $0,
                    cacheDirectory: cacheDirectory,
                    existing: byIdentifier,
                    context: context
                )
            }
            photos.append(contentsOf: chunk)
            try? context.save()
            index = end
            await Task.yield()
        }
        if generation == photoStagingGeneration { photoStagingTask = nil }
    }

    private func resolvePhotosLibraryPhoto(
        for asset: PHAsset,
        cacheDirectory: URL,
        existing byIdentifier: [String: Photo],
        context: ModelContext
    ) -> Photo {
        if let photo = byIdentifier[asset.localIdentifier] { return photo }
        let fileURL = cacheDirectory.appendingPathComponent(Self.sanitizedAssetFileName(asset.localIdentifier))
        let photo = Photo(fileURL: fileURL, phAssetLocalIdentifier: asset.localIdentifier)
        photo.shootingDate = asset.creationDate ?? Date()
        context.insert(photo)
        return photo
    }

    private static func sanitizedAssetFileName(_ localIdentifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = localIdentifier.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "_"
        }
        return String(sanitized) + ".jpg"
    }
}
