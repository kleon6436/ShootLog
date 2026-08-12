import SwiftData
import Foundation

// 写真選択・お気に入り・メモ・EXIF遅延取得・外部アプリ起動・分析シート表示を担当する
extension ContentViewModel {
    // MARK: - Photo Navigation

    // 写真を選択し EditInfo と EXIF を遅延ロードする
    func selectPhoto(_ photo: Photo?) {
        selectedPhoto = photo
        guard let photo else { currentEditInfo = nil; return }
        loadEditInfo(for: photo)
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

    func saveNote(_ note: String, for photo: Photo) {
        photo.note = note
        if let context = modelContext { saveOrReportError(context) }
    }

    // 成功要因タグの唯一の書込経路。配列の追加/削除判定はView側に持たせずここに閉じる
    func toggleSuccessTag(_ tag: SuccessTagCategory, for photo: Photo) {
        var tags = photo.successTags
        if let index = tags.firstIndex(of: tag) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        photo.successTags = tags
        if let context = modelContext { saveOrReportError(context) }
    }

    // Step 3: 選択時に EXIF を遅延ロードして Photo に永続化する
    func loadEXIFIfNeeded(for photo: Photo) async {
        guard photo.exifFetchedAt == nil else { return }
        let url = photo.fileURL
        do {
            let exif = try await EXIFService.shared.readEXIF(from: url)
            apply(exif, to: photo)
            // バックグラウンドのEXIF取得処理。失敗しても一覧表示は継続するためAlert化しない
            try? modelContext?.save()
        } catch {
            // EXIF 読み取り失敗は非致命的。無視する
        }
    }

    // 読み取った EXIF を Photo へ反映する（保存は呼び出し側でまとめて行う）
    private func apply(_ exif: EXIFInfo, to photo: Photo) {
        photo.cameraMake   = exif.cameraMake
        photo.cameraModel  = exif.cameraModel
        photo.lensModel    = exif.lensModel
        photo.aperture     = exif.aperture
        photo.shutterSpeed = exif.shutterSpeed
        photo.iso          = exif.iso
        photo.focalLength  = exif.focalLength
        photo.colorMode    = exif.colorMode
        if let date = exif.shootingDate { photo.shootingDate = date }
        photo.exifFetchedAt = Date()
    }

    // MARK: - External App

    // 選択中写真を指定の外部アプリで開く
    func openInExternalApp(_ adapter: any ExternalAppProtocol) {
        guard let url = selectedPhoto?.fileURL else { return }
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
