import Foundation

// AI被写体認識のバックグラウンド実行と結果反映を担当する。フォルダ読み込みと
// iCloud写真ライブラリ読み込みの両方から呼ぶ。状態（aiLabeling*）はストアドプロパティのため
// ContentViewModel.swift 側に置いている
extension ContentViewModel {
    // targetPhotos と photoIndex は呼び出し側が EXIF 先読みの await より前に計算して渡す
    // （待機中に photos が差し替わっても、開始時点の対象と索引で結果を反映するため）
    func startAILabeling(
        targetPhotos: [Photo],
        photoIndex: [URL: Int],
        snapshots: [URL: FileAttributesSnapshot],
        token aiLabelingToken: Int
    ) async {
        let aiTargets = targetPhotos.map {
            AILabelingTarget(
                url: $0.fileURL,
                localIdentifier: $0.phAssetLocalIdentifier,
                snapshot: snapshots[$0.fileURL]
            )
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
                    if let index = photoIndex[url], self.photos.indices.contains(index) {
                        let photo = self.photos[index]
                        if let result {
                            photo.aiCategoryRawValues = result.categories.map(\.rawValue)
                            photo.aiRawIdentifiers = result.rawIdentifiers
                            photo.aiLabelingFetchedAt = Date()
                            photo.aiLabelingFailedAt = nil
                            self.addDetectedAICategories(result.categories)
                        } else {
                            // キャンセル時は onResult が呼ばれないため、ここに来るのは実際の失敗だけ。
                            // 既存の分類結果があれば残す
                            photo.aiLabelingFailedAt = Date()
                        }
                        photo.aiLabelingSchemaVersion = AILabelingGenerator.currentSchemaVersion
                    }
                    self.aiLabelingCompletedCount += 1
                    // 書き込み後に保存し、数百〜数千枚の分類ではチャンク単位にI/Oする。
                    if aiTotal > 0,
                       self.aiLabelingCompletedCount == aiTotal
                        || self.aiLabelingCompletedCount.isMultiple(of: Self.photoStagingChunkSize) {
                        try? self.modelContext?.save()
                    }
                }
            }
        )
    }

    // 未分類、または分類ロジックの世代が古い写真を再分類の対象にする。
    // 前回失敗した写真は、失敗の原因が解消し得る場合だけ対象に戻す
    func aiLabelingTargetPhotos(now: Date = Date()) -> [Photo] {
        photos.filter { photo in
            if let failedAt = photo.aiLabelingFailedAt {
                return shouldRetryAIFailure(
                    of: photo,
                    failedAt: failedAt,
                    failedSchemaVersion: photo.aiLabelingSchemaVersion,
                    currentSchemaVersion: AILabelingGenerator.currentSchemaVersion,
                    now: now
                )
            }
            return photo.aiLabelingFetchedAt == nil
                || (photo.aiLabelingSchemaVersion ?? 1) < AILabelingGenerator.currentSchemaVersion
        }
    }

    /// iCloud写真の失敗を再試行するまでの間隔。通信状況やエクスポートの有無で結果が変わり得る
    static let aiFailureRetryInterval: TimeInterval = 24 * 60 * 60

    /// 被写体認識・画質診断で前回失敗した写真を再試行するか。
    /// 失敗を毎回やり直すと、読めないファイルがある限り進捗表示がフォルダを開くたびに出て終わらないため、
    /// 処理ロジックの世代が上がった・フォルダ写真のファイルが差し替えられた・iCloud写真で一定時間経った、
    /// のいずれかに限る
    func shouldRetryAIFailure(
        of photo: Photo,
        failedAt: Date,
        failedSchemaVersion: Int?,
        currentSchemaVersion: Int,
        now: Date = Date()
    ) -> Bool {
        if (failedSchemaVersion ?? 1) < currentSchemaVersion { return true }
        if photo.phAssetLocalIdentifier != nil {
            return now.timeIntervalSince(failedAt) >= Self.aiFailureRetryInterval
        }
        // スキャン時のスナップショットだけを見る（MainActor 上で個別にファイル属性を読まない）
        guard let modificationDate = fileAttributesSnapshots[photo.fileURL]?.modificationDate else {
            return false
        }
        return modificationDate > failedAt
    }

    // 結果を反映する写真の索引（fileURL → photos 内の位置）
    func photoIndexByURL() -> [URL: Int] {
        Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.fileURL, $0) })
    }
}
