import Foundation
import Photos
import SwiftData

@MainActor
extension ContentViewModel {
    func openPhotosLibrary() {
        // ダブルクリック等で読み込みが並走すると、同じアセットの Photo 行を二重に作り得るため
        // 進行中の要求があれば新しい要求は無視する
        guard photosLibraryOpenTask == nil else { return }
        photosLibraryOpenTask = Task {
            defer { photosLibraryOpenTask = nil }
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
        // cancelPhotoStaging の await 中に別の読み込みが割り込んでも世代を共有しないよう、
        // この読み込み専用の世代を発行する（以降の await 明けで最新かどうかを判定する）
        photoStagingGeneration &+= 1
        let generation = photoStagingGeneration
        guard applyFileAttributesSnapshots([:], generation: generation) else { return }
        isLoading = true
        photos = []
        selectedPhoto = nil
        currentEditInfo = nil
        currentDevelopSettings = nil
        isCropMode = false

        let assets = await Task.detached(priority: .utility) {
            PhotosLibraryRepository.fetchAssets()
        }.value
        // 待機中にフォルダ読み込み等へ切り替わっていたら、この読み込みは破棄する
        // （isLoading は新しい読み込み側が管理するため触らない。ContentViewModelFolder と同じ方針）
        guard generation == photoStagingGeneration else { return }
        let (byIdentifier, originalFileNames) = await resolveOriginalFileNames(for: assets, context: context)
        guard generation == photoStagingGeneration else { return }
        let cacheDirectory = PhotosLibraryAssetExporter.defaultDirectory
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            }.value
        } catch {
            guard generation == photoStagingGeneration else { return }
            self.error = error
            isLoading = false
            return
        }
        // 既存行の取得（resolveOriginalFileNames）から挿入（syncPhotosLibrary）までの間に
        // 別の読み込みが走っていれば、同じアセットの行を二重に作らないようここで打ち切る
        guard generation == photoStagingGeneration else { return }

        syncPhotosLibrary(
            assets: assets,
            existing: byIdentifier,
            originalFileNames: originalFileNames,
            context: context
        )
        selectPhoto(photos.first)
        let aiLabelingToken = beginAILabeling()
        let aiQualityDiagnosisToken = beginAIQualityDiagnosis()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let staging = self.photoStagingTask {
                await staging.value
            }
            guard aiLabelingToken == self.aiLabelingToken else { return }

            self.resetDetectedAICategories(from: self.photos)
            await self.startAILabeling(
                targetPhotos: self.aiLabelingTargetPhotos(),
                photoIndex: self.photoIndexByURL(),
                snapshots: [:],
                token: aiLabelingToken
            )
            await self.startAIQualityDiagnosis(token: aiQualityDiagnosisToken, around: 0)
        }
        isLoading = false
    }

    private func resolveOriginalFileNames(
        for assets: [PHAsset],
        context: ModelContext
    ) async -> (byIdentifier: [String: Photo], originalFileNames: [String: String]) {
        let all = (try? context.fetch(FetchDescriptor<Photo>())) ?? []
        let byIdentifier = Dictionary(
            all.compactMap { photo in
                photo.phAssetLocalIdentifier.map { ($0, photo) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let assetsNeedingOriginalFileNames = assets.filter {
            byIdentifier[$0.localIdentifier]?.originalFileName == nil
        }
        let originalFileNames: [String: String] = await Task.detached(priority: .utility) {
            Dictionary(
                assetsNeedingOriginalFileNames.compactMap { asset in
                    guard let originalFileName = PHAssetResource
                        .assetResources(for: asset)
                        .first?.originalFilename else { return nil }
                    return (asset.localIdentifier, originalFileName)
                },
                uniquingKeysWith: { first, _ in first }
            )
        }.value
        return (byIdentifier, originalFileNames)
    }

    private func syncPhotosLibrary(
        assets: [PHAsset],
        existing byIdentifier: [String: Photo],
        originalFileNames: [String: String],
        context: ModelContext
    ) {
        let firstBatchCount = min(assets.count, Self.initialPhotoBatchSize)
        photos = assets[..<firstBatchCount].map {
            resolvePhotosLibraryPhoto(
                for: $0,
                existing: byIdentifier,
                originalFileNames: originalFileNames,
                context: context
            )
        }
        saveOrReportError(context)

        guard firstBatchCount < assets.count else { return }
        let remaining = Array(assets[firstBatchCount...])
        let generation = photoStagingGeneration
        // 前回の段階挿入が残っていれば上書きで取りこぼさず、明示的に止めてから差し替える
        photoStagingTask?.cancel()
        photoStagingTask = Task {
            await stagePhotosLibraryPhotos(
                assets: remaining,
                existing: byIdentifier,
                originalFileNames: originalFileNames,
                context: context,
                generation: generation
            )
        }
    }

    private func stagePhotosLibraryPhotos(
        assets: [PHAsset],
        existing byIdentifier: [String: Photo],
        originalFileNames: [String: String],
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
                    originalFileNames: originalFileNames,
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
        originalFileNames: [String: String],
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
            if photo.originalFileName == nil {
                photo.originalFileName = originalFileNames[asset.localIdentifier]
            }
            return photo
        }
        let photo = Photo(fileURL: fileURL, phAssetLocalIdentifier: asset.localIdentifier)
        photo.originalFileName = originalFileNames[asset.localIdentifier]
        photo.shootingDate = asset.creationDate ?? Date()
        context.insert(photo)
        return photo
    }

}
