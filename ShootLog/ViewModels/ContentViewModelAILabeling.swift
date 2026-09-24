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
                    if let result,
                       let index = photoIndex[url], self.photos.indices.contains(index) {
                        let photo = self.photos[index]
                        photo.aiCategoryRawValues = result.categories.map(\.rawValue)
                        photo.aiRawIdentifiers = result.rawIdentifiers
                        photo.aiLabelingFetchedAt = Date()
                        photo.aiLabelingSchemaVersion = AILabelingGenerator.currentSchemaVersion
                        self.addDetectedAICategories(result.categories)
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

    // 未分類、または分類ロジックの世代が古い写真を再分類の対象にする
    func aiLabelingTargetPhotos() -> [Photo] {
        photos.filter {
            $0.aiLabelingFetchedAt == nil
                || ($0.aiLabelingSchemaVersion ?? 1) < AILabelingGenerator.currentSchemaVersion
        }
    }

    // 結果を反映する写真の索引（fileURL → photos 内の位置）
    func photoIndexByURL() -> [URL: Int] {
        Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.fileURL, $0) })
    }
}
