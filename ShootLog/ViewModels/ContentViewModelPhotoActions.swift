import SwiftData
import Foundation

// 写真選択・お気に入り・メモ・EXIF遅延取得・外部アプリ起動・分析シート表示を担当する
extension ContentViewModel {
    // MARK: - Photo Navigation

    // 写真を選択し EditInfo と EXIF を遅延ロードする
    func selectPhoto(_ photo: Photo?) {
        // トリミング中に別の写真へ切り替わると、前の写真基準の矩形を操作し続けてしまうため
        // 選択のたびにトリミングモードを解除する
        isCropMode = false
        selectedPhoto = photo
        guard let photo else {
            currentEditInfo = nil
            currentDevelopSettings = nil
            return
        }
        loadEditInfo(for: photo)
        loadDevelopSettings(for: photo)
        Task { await loadEXIFIfNeeded(for: photo) }
    }

    // visiblePhotos（showFavoritesOnly適用後）基準で次の写真を選択する。
    // 選択中写真が未選択、または絞り込みで一覧から外れている場合は先頭要素を選ぶ
    // （旧実装は selectedIndex の `?? 0` フォールバックにより未選択時に1枚飛ばすバグがあった）
    func selectNext() {
        let list = visiblePhotos
        guard !list.isEmpty else { return }
        guard let selectedPhoto, let index = list.firstIndex(where: { $0.id == selectedPhoto.id }) else {
            selectPhoto(list.first)
            return
        }
        // 段階挿入中に「まだ挿入されていない次の写真」が存在し得る場合に限り、挿入完了を待って再試行する。
        // 絞り込み末尾が全体の末尾と一致しない場合（お気に入りのみ表示など）は待たずに即クランプする
        if index == list.count - 1,
           let staging = photoStagingTask,
           list.last?.id == photos.last?.id {
            let generation = photoStagingGeneration
            let targetID = selectedPhoto.id
            pendingSelectNextTask?.cancel()
            pendingSelectNextTask = Task { [weak self] in
                await staging.value
                guard let self, !Task.isCancelled,
                      generation == self.photoStagingGeneration,
                      self.selectedPhoto?.id == targetID else { return }
                self.pendingSelectNextTask = nil
                self.selectNext()
            }
            return
        }
        selectPhoto(list[min(index + 1, list.count - 1)])
    }

    func selectPrevious() {
        let list = visiblePhotos
        guard !list.isEmpty else { return }
        guard let selectedPhoto, let index = list.firstIndex(where: { $0.id == selectedPhoto.id }) else {
            selectPhoto(list.first)
            return
        }
        selectPhoto(list[max(index - 1, 0)])
    }

    // MARK: - Photo Actions

    // 選択中写真のお気に入りをトグルする（FullscreenMode・SlideshowMode用）
    func toggleFavorite() {
        guard let photo = selectedPhoto else { return }
        toggleFavorite(photo)
    }

    // グリッド・リストからの直接トグル用
    func toggleFavorite(_ photo: Photo) {
        photo.isFavorite.toggle()
        guard let context = modelContext, saveOrReportError(context) else { return }
        showToast(photo.isFavorite
            ? String(localized: "toast.favorite.added")
            : String(localized: "toast.favorite.removed"))
    }

    // 成功要因タグの唯一の書込経路。配列の追加/削除判定はView側に持たせずここに閉じる。
    // 右クリックメニューからはタグの状態が画面に出ないため、toggleFavorite と同じく
    // 保存に成功したときだけトーストで結果を知らせる
    func toggleSuccessTag(_ tag: SuccessTagCategory, for photo: Photo) {
        var tags = photo.successTags
        let isAdding = !tags.contains(tag)
        if let index = tags.firstIndex(of: tag) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        photo.successTags = tags
        guard let context = modelContext, saveOrReportError(context) else { return }
        showToast(isAdding
            ? String(localized: "toast.successTag.added \(tag.displayName)")
            : String(localized: "toast.successTag.removed \(tag.displayName)"))
    }

    // MARK: - Pasteboard

    // ファイル名をパスボードへコピーする（グリッドの右クリックメニュー用）
    func copyFileNameToPasteboard() {
        guard let photo = selectedPhoto else { return }
        pasteboardWriter.writeText(photo.displayFileName)
        showToast(String(localized: "toast.copied.fileName"))
    }

    // 原本ファイルのパスをパスボードへコピーする。
    // iCloud写真のパスは eviction 対象の一時キャッシュを指すためコピーさせない
    func copyFilePathToPasteboard() {
        guard let photo = selectedPhoto,
              PhotoActionAvailability(photo: photo).canCopyPath else { return }
        pasteboardWriter.writeFileURL(photo.fileURL)
        showToast(String(localized: "toast.copied.path"))
    }

    // Step 3: 選択時に EXIF を遅延ロードして Photo に永続化する
    func loadEXIFIfNeeded(for photo: Photo) async {
        var canReadFile = true
        if let localIdentifier = photo.phAssetLocalIdentifier {
            let fileURL = photo.fileURL
            canReadFile = await PhotosLibraryAssetExporter.shared.ensureExported(
                localIdentifier: localIdentifier,
                fileURL: fileURL
            )
        }
        if canReadFile, photo.exifFetchedAt == nil {
            let url = photo.fileURL
            do {
                let exif = try await EXIFService.shared.readEXIF(
                    from: url,
                    snapshot: fileAttributesSnapshots[url]
                )
                apply(exif, to: photo)
                // バックグラウンドのEXIF取得処理。失敗しても一覧表示は継続するためAlert化しない
                try? modelContext?.save()
            } catch {
                // EXIF 読み取り失敗は非致命的。無視する
            }
        }
        _ = await asShotWhiteBalance(for: photo)
    }

    /// 永続値を優先して撮影時ホワイトバランスを返し、未取得時は画像から取得して保存する。
    func asShotWhiteBalance(for photo: Photo) async -> WhiteBalanceSample? {
        if photo.asShotWhiteBalanceFetchedAt != nil {
            guard let temperature = photo.asShotTemperatureKelvin,
                  let tint = photo.asShotTint,
                  let isEstimated = photo.asShotWhiteBalanceIsEstimated else {
                return nil
            }
            return WhiteBalanceSample(
                temperatureKelvin: temperature,
                tint: tint,
                isEstimated: isEstimated
            )
        }

        let sample = await ImageDevelopmentEngine.shared.asShotNeutral(for: photo.fileURL)
        if let sample {
            photo.asShotTemperatureKelvin = sample.temperatureKelvin
            photo.asShotTint = sample.tint
            photo.asShotWhiteBalanceIsEstimated = sample.isEstimated
        }
        // 取得不能も記録し、ファイルが壊れている場合に選択のたび再試行しない。
        photo.asShotWhiteBalanceFetchedAt = Date()
        try? modelContext?.save()
        return sample
    }

    // 読み取った EXIF を Photo へ反映する（保存は呼び出し側でまとめて行う）
    // フォルダのEXIF先読み結果を別extensionから共通利用するためinternalにする。
    func apply(_ exif: EXIFInfo, to photo: Photo) {
        photo.cameraMake   = exif.cameraMake
        photo.cameraModel  = exif.cameraModel
        photo.lensModel    = exif.lensModel
        photo.aperture     = exif.aperture
        photo.shutterSpeed = exif.shutterSpeed
        photo.iso          = exif.iso
        photo.focalLength  = exif.focalLength
        photo.colorMode    = exif.colorMode
        photo.pixelWidth   = exif.pixelWidth
        photo.pixelHeight  = exif.pixelHeight
        photo.fileSizeBytes = exif.fileSizeBytes
        if let date = exif.shootingDate { photo.shootingDate = date }
        photo.exifFetchedAt = Date()
    }

    // MARK: - External App

    // 選択中写真を指定の外部アプリで開く。
    // iCloud写真は fileURL がエクスポート前のプレースホルダーパスのため、
    // 実ファイルの書き出しを待ってから開く（loadEXIFIfNeeded と同じ経路）
    func openInExternalApp(_ adapter: any ExternalAppProtocol) {
        guard let photo = selectedPhoto else { return }
        let url = photo.fileURL
        guard let localIdentifier = photo.phAssetLocalIdentifier else {
            adapter.open(url: url)
            return
        }
        Task {
            let isExported = await PhotosLibraryAssetExporter.shared.ensureExported(
                localIdentifier: localIdentifier,
                fileURL: url
            )
            guard isExported else {
                showToast(String(localized: "toast.externalApp.exportFailed"))
                return
            }
            adapter.open(url: url)
        }
    }

    // 任意のURLを指定の外部アプリで開く（超解像書き出し完了後の「他のアプリで開く」用）。
    // 呼び出し前にアプリの利用可否を確認し、falseならエラーを通知して開かない
    func openInExternalApp(url: URL, adapter: any ExternalAppProtocol) {
        guard adapter.isAvailable else {
            error = ShootLogError.applicationInfoUnavailable(name: adapter.displayName)
            return
        }
        adapter.open(url: url)
    }

    // MARK: - Analysis

    // 分析シートを開き、未取得EXIFをバックグラウンドで一括ロードする。
    // AnalysisView は初期化時の写真配列をスナップショットするため、段階挿入中は
    // 全件の挿入完了を待ってからシートを開く（部分集合のまま分析されるのを防ぐ）。
    // @Model は Sendable でないため URL のみを EXIFService へ渡し、読み取りは並列数制限付きで並列化する
    func openAnalysis() {
        guard !photos.isEmpty else { return }
        analysisTask?.cancel()
        analysisTask = Task {
            let generation = photoStagingGeneration
            if let staging = photoStagingTask {
                isLoading = true
                await staging.value
                // フォルダが切り替わった場合は、その分析要求自体を破棄する
                // （isLoading は新しい読み込み側が管理するため触らない）
                guard generation == photoStagingGeneration else { return }
                isLoading = false
            }
            guard !Task.isCancelled, !photos.isEmpty else { return }
            showAnalysis = true

            let targets = photos.filter { $0.exifFetchedAt == nil }
            guard !targets.isEmpty else { return }
            let urls = targets.map(\.fileURL)
            let results = await EXIFService.shared.readEXIFBatch(
                from: urls,
                snapshots: fileAttributesSnapshots,
                maxConcurrency: EXIFService.recommendedBatchConcurrency(for: urls.first)
            )
            guard !Task.isCancelled else { return }
            for photo in targets {
                guard let exif = results[photo.fileURL] else { continue }
                apply(exif, to: photo)
            }
            // 分析シート向けのバックグラウンド一括取得。失敗しても分析表示自体は継続するためAlert化しない
            try? modelContext?.save()
        }
    }
}
