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
    func startAIQualityDiagnosis(token: Int, around selectedIndex: Int?) async {
        guard token == aiQualityDiagnosisToken else { return }

        let targets = photos
            .filter {
                $0.aiDiagnosisFetchedAt == nil
                    || ($0.aiDiagnosisSchemaVersion ?? 1) < PhotoQualityDiagnosisGenerator.currentSchemaVersion
            }
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

    // 画像自体を解決できなかった場合（プロキシ未生成・iCloud未エクスポート等の一時的要因が多い）は
    // fetchedAt を立てず、次回のフォルダ／iCloudライブラリ再訪で再診断できるようにする。
    // Vision処理が失敗しただけ（画像は解決できた＝diagnosisは非nil）のときは、従来通り fetchedAt を
    // 立てて無限リトライを防ぐ。
    private func apply(_ diagnosis: PhotoQualityDiagnosis?, to photo: Photo) {
        guard let diagnosis else { return }
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
