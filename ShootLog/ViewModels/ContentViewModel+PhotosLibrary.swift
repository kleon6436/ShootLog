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
        let cacheDirectory = PhotosLibraryAssetExporter.defaultDirectory
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            }.value
        } catch {
            self.error = error
            isLoading = false
            return
        }

        syncPhotosLibrary(assets: assets, context: context)
        selectPhoto(photos.first)
        let aiLabelingToken = beginAILabeling()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let staging = self.photoStagingTask {
                await staging.value
            }
            guard aiLabelingToken == self.aiLabelingToken else { return }

            self.resetDetectedAICategories(from: self.photos)
            let targetPhotos = self.photos
                .filter { $0.aiLabelingFetchedAt == nil }
            let photoIndex = Dictionary(
                uniqueKeysWithValues: self.photos.enumerated().map { ($1.fileURL, $0) }
            )
            let aiTargets = targetPhotos.map {
                AILabelingTarget(url: $0.fileURL, localIdentifier: $0.phAssetLocalIdentifier)
            }
            let aiTotal = aiTargets.count
            await AILabelingGenerator.shared.start(
                targets: aiTargets,
                around: 0,
                progress: { [weak self] done, total in
                    Task { @MainActor in
                        guard let self else { return }
                        guard aiLabelingToken == self.aiLabelingToken else { return }
                        self.updateAILabelingProgress(done: done, total: total)
                    }
                },
                onResult: { [weak self] url, result in
                    Task { @MainActor in
                        guard let self else { return }
                        guard aiLabelingToken == self.aiLabelingToken else { return }
                        if let result,
                           let index = photoIndex[url], self.photos.indices.contains(index) {
                            let photo = self.photos[index]
                            photo.aiCategoryRawValues = result.categories.map(\.rawValue)
                            photo.aiRawIdentifiers = result.rawIdentifiers
                            photo.aiLabelingFetchedAt = Date()
                            self.addDetectedAICategories(result.categories)
                        }
                        self.aiLabelingCompletedCount += 1
                        if aiTotal > 0,
                           self.aiLabelingCompletedCount == aiTotal
                            || self.aiLabelingCompletedCount.isMultiple(of: Self.photoStagingChunkSize) {
                            try? self.modelContext?.save()
                        }
                    }
                }
            )
        }
        isLoading = false
    }

    private func syncPhotosLibrary(
        assets: [PHAsset],
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
                existing: byIdentifier,
                context: context,
                generation: generation
            )
        }
    }

    private func stagePhotosLibraryPhotos(
        assets: [PHAsset],
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
        existing byIdentifier: [String: Photo],
        context: ModelContext
    ) -> Photo {
        let fileURL = PhotosLibraryAssetExporter.fileURL(forLocalIdentifier: asset.localIdentifier)
        if let photo = byIdentifier[asset.localIdentifier] {
            if photo.fileURL != fileURL {
                // 新しいエクスポート先の中身は未確認のため、保存済みの読み取り結果を無効化する。
                photo.fileURL = fileURL
                photo.exifFetchedAt = nil
                photo.asShotWhiteBalanceFetchedAt = nil
            }
            return photo
        }
        let photo = Photo(fileURL: fileURL, phAssetLocalIdentifier: asset.localIdentifier)
        photo.shootingDate = asset.creationDate ?? Date()
        context.insert(photo)
        return photo
    }

}
