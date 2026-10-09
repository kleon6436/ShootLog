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
        // 手動の再解析で世代が進んでいたら、古い対象で生成器を上書きしない
        guard aiLabelingToken == self.aiLabelingToken else { return }
        let aiTargets = targetPhotos.map {
            AILabelingTarget(
                url: $0.fileURL,
                localIdentifier: $0.phAssetLocalIdentifier,
                snapshot: snapshots[$0.fileURL]
            )
        }
        let aiTotal = aiTargets.count
        await aiLabelingGenerator.start(
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
                    self.aiLabelingReanalysisURLs.remove(url)
                    // 索引はバッチ開始時点の photos 基準。写真ソースの切り替え途中に届いた結果を
                    // 別の写真へ書き込まないよう、URL が一致する場合だけ反映する
                    if let index = photoIndex[url], self.photos.indices.contains(index),
                       self.photos[index].fileURL == url {
                        let photo = self.photos[index]
                        if let result {
                            photo.aiCategoryRawValues = result.categories.map(\.rawValue)
                            photo.aiRawIdentifiers = result.rawIdentifiers
                            photo.aiLabelingFetchedAt = Date()
                            photo.aiLabelingFailedAt = nil
                            self.addDetectedAICategories(result.categories)
                        } else {
                            // キャンセル時は onResult が呼ばれないため、ここに来るのは実際の失敗だけ。
                            // 既存の分類結果があれば残す。ただし旧スキーマ版の結果は誤分類を含み得るため、
                            // 現行版の印を付けて残すと「現行版の結果」として扱われ続けてしまう。消してから失敗を記録する
                            if (photo.aiLabelingSchemaVersion ?? 1) < AILabelingGenerator.currentSchemaVersion {
                                photo.aiCategoryRawValues = []
                                photo.aiRawIdentifiers = []
                                photo.aiLabelingFetchedAt = nil
                            }
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
            if aiLabelingReanalysisURLs.contains(photo.fileURL) { return true }
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

// MARK: - 手動の再解析

extension ContentViewModel {
    /// 被写体認識・画質診断で失敗を記録した写真。ツールバーの一括再解析の対象
    var aiAnalysisFailedPhotos: [Photo] {
        photos.filter { $0.aiLabelingFailedAt != nil || $0.aiDiagnosisFailedAt != nil }
    }

    /// `urls` に含まれる写真を先頭へ寄せる。それぞれの中では元の並び（写真一覧の順）を保つ
    static func prioritizing(_ urls: Set<URL>, in photos: [Photo]) -> [Photo] {
        guard !urls.isEmpty else { return photos }
        return photos.filter { urls.contains($0.fileURL) } + photos.filter { !urls.contains($0.fileURL) }
    }

    /// 指定した写真の被写体認識と画質診断を、分類済み・失敗済みかに関わらずやり直す。
    /// 指定した写真を先頭に、まだ処理していない写真も含めて現在の写真ソースのバッチを組み直す。
    func reanalyzeAI(_ requested: [Photo]) {
        guard !requested.isEmpty else { return }
        // 写真ソースの切り替え中（cancelPhotoStaging の待機中）に始めると、旧ソースの写真を
        // セキュリティスコープ解放後に解析して失敗を記録してしまうため受け付けない
        guard photoStagingCancelCount == 0 else { return }
        let urls = Set(requested.map(\.fileURL))
        aiLabelingReanalysisURLs.formUnion(urls)
        aiQualityDiagnosisReanalysisURLs.formUnion(urls)
        showToast(String(localized: "toast.aiReanalysisStarted \(requested.count)"))

        // 写真の段階挿入中は、フォルダ読み込み側のバックグラウンド解析がまだ始まっていない。
        // 世代を進めるとその解析（EXIF先読み・キャプション生成を含む）を止めてしまうため、
        // 対象に加えるだけにして、あちらの開始時に拾わせる
        guard photoStagingTask == nil else { return }

        let labelingToken = beginAILabeling()
        let diagnosisToken = beginAIQualityDiagnosis()
        let targetPhotos = Self.prioritizing(urls, in: aiLabelingTargetPhotos())
        let photoIndex = photoIndexByURL()
        let snapshots = fileAttributesSnapshots
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startAILabeling(
                targetPhotos: targetPhotos,
                photoIndex: photoIndex,
                snapshots: snapshots,
                token: labelingToken
            )
            await self.startAIQualityDiagnosis(token: diagnosisToken, around: nil, prioritizing: urls)
        }
    }
}
