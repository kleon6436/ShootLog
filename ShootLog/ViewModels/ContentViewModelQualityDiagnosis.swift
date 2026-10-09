import Foundation

// AI画質診断のバックグラウンド実行・進捗・結果反映を担当する。
// 状態（aiQualityDiagnosis* / qualityDiagnosisGenerator）はストアドプロパティのため
// ContentViewModel.swift 側に置いている
extension ContentViewModel {
    // MARK: - Progress

    func updateAIQualityDiagnosisProgress(done: Int, total: Int) {
        aiQualityDiagnosisRemaining = max(0, total - done)
    }

    func beginAIQualityDiagnosis() -> Int {
        aiQualityDiagnosisToken &+= 1
        aiQualityDiagnosisCompletedCount = 0
        clearAIQualityDiagnosisProgress()
        return aiQualityDiagnosisToken
    }

    func clearAIQualityDiagnosisProgress() {
        aiQualityDiagnosisRemaining = 0
    }

    func cancelAIQualityDiagnosis() {
        aiQualityDiagnosisToken &+= 1
        clearAIQualityDiagnosisProgress()
    }

    // MARK: - Diagnosis

    /// 画質診断をバックグラウンドで開始する。フォルダ／iCloud写真ライブラリ双方の読み込みから呼ぶ。
    /// - Parameter prioritizing: 手動の再解析で先に処理する写真。`selectedIndex` の近傍より優先する
    func startAIQualityDiagnosis(
        token: Int,
        around selectedIndex: Int?,
        prioritizing prioritizedURLs: Set<URL> = []
    ) async {
        guard token == aiQualityDiagnosisToken else { return }

        let targets = Self.prioritizing(prioritizedURLs, in: aiQualityDiagnosisTargetPhotos())
            .map {
                AILabelingTarget(
                    url: $0.fileURL,
                    localIdentifier: $0.phAssetLocalIdentifier,
                    snapshot: fileAttributesSnapshots[$0.fileURL]
                )
            }
        let photoIndex = Dictionary(
            uniqueKeysWithValues: photos.enumerated().map { ($1.fileURL, $0) }
        )
        let total = targets.count

        await qualityDiagnosisGenerator.start(
            targets: targets,
            around: selectedIndex,
            progress: { [weak self] done, total in
                Task { @MainActor in
                    guard let self else { return }
                    guard token == self.aiQualityDiagnosisToken else { return }
                    self.updateAIQualityDiagnosisProgress(done: done, total: total)
                }
            },
            onResult: { [weak self] url, diagnosis in
                Task { @MainActor in
                    guard let self else { return }
                    guard token == self.aiQualityDiagnosisToken else { return }
                    self.aiQualityDiagnosisReanalysisURLs.remove(url)
                    if let index = photoIndex[url], self.photos.indices.contains(index) {
                        self.apply(diagnosis, to: self.photos[index])
                    }
                    self.aiQualityDiagnosisCompletedCount += 1
                    // 書き込み後に保存し、数百〜数千枚の診断ではチャンク単位にI/Oする。
                    if total > 0,
                       self.aiQualityDiagnosisCompletedCount == total
                        || self.aiQualityDiagnosisCompletedCount.isMultiple(of: Self.photoStagingChunkSize) {
                        try? self.modelContext?.save()
                    }
                }
            }
        )
    }

    // 未診断、または診断ロジックの世代が古い写真を対象にする。
    // 前回失敗した写真は、被写体認識と同じ条件（shouldRetryAIFailure）でだけ対象に戻す
    func aiQualityDiagnosisTargetPhotos(now: Date = Date()) -> [Photo] {
        photos.filter { photo in
            if aiQualityDiagnosisReanalysisURLs.contains(photo.fileURL) { return true }
            if let failedAt = photo.aiDiagnosisFailedAt {
                return shouldRetryAIFailure(
                    of: photo,
                    failedAt: failedAt,
                    failedSchemaVersion: photo.aiDiagnosisSchemaVersion,
                    currentSchemaVersion: PhotoQualityDiagnosisGenerator.currentSchemaVersion,
                    now: now
                )
            }
            return photo.aiDiagnosisFetchedAt == nil
                || (photo.aiDiagnosisSchemaVersion ?? 1) < PhotoQualityDiagnosisGenerator.currentSchemaVersion
        }
    }

    // 画像を解決できなかった・Visionが結果を返さなかった場合は fetchedAt を立てずに失敗日時を記録する。
    // 毎回再診断すると読めない写真がある限り進捗表示が終わらないため、再試行は shouldRetryAIFailure に従う。
    // Vision が一部スコアしか返せなかった（diagnosis は非nil）ときは診断済みとして扱う。
    private func apply(_ diagnosis: PhotoQualityDiagnosis?, to photo: Photo) {
        guard let diagnosis else {
            photo.aiDiagnosisFailedAt = Date()
            photo.aiDiagnosisSchemaVersion = PhotoQualityDiagnosisGenerator.currentSchemaVersion
            return
        }
        photo.aiDiagnosisFailedAt = nil
        photo.aiAestheticsOverallScore = diagnosis.aestheticsScore
        photo.aiAestheticsIsUtility = diagnosis.isUtility
        photo.aiFaceQualityScore = diagnosis.faceQualityScore
        photo.aiExposureBias = diagnosis.exposureBias
        photo.aiSharpnessScore = diagnosis.sharpnessScore
        photo.aiCompositionOffsetScore = diagnosis.compositionOffsetScore
        photo.aiDiagnosisFetchedAt = Date()
        photo.aiDiagnosisSchemaVersion = PhotoQualityDiagnosisGenerator.currentSchemaVersion
    }
}
