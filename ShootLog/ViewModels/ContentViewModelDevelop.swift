import Foundation
import SwiftData

// RAW 現像 / 非破壊カラー編集の調整値の永続化を担当する。
// 回転・トリミング（ContentViewModelEdit.swift）とは独立して扱う
extension ContentViewModel {
    // MARK: - Develop

    // 選択中写真の DevelopSettings を SwiftData から取得する（なければ nil）
    // フェッチは #Predicate での UUID フィルタが不安定なケースに備え、loadEditInfo と同じ
    // 「全件 fetch して first(where:)」パターンを踏襲する（ContentViewModelEdit.swift参照）
    func loadDevelopSettings(for photo: Photo) {
        guard let context = modelContext else { return }
        let all = (try? context.fetch(FetchDescriptor<DevelopSettings>())) ?? []
        currentDevelopSettings = all.first(where: { $0.photoID == photo.id })
    }

    // 指定写真の DevelopSettings を返す（なければ nil）。選択切り替え直後は currentDevelopSettings が
    // 既に次の写真を指していることがあるため、photoID が一致するときだけキャッシュを使う。
    // 選択中写真のキャッシュは selectPhoto で loadDevelopSettings 済み（行が無ければ nil）なので
    // 引き直さない（描画のたびに全件 fetch しないため）。それ以外の写真はストアから引く
    func developSettings(forPhotoID photoID: UUID) -> DevelopSettings? {
        if let cached = currentDevelopSettings, cached.photoID == photoID { return cached }
        if selectedPhoto?.id == photoID { return nil }
        guard let context = modelContext else { return nil }
        return storedDevelopSettings(forPhotoID: photoID, context: context)
    }

    // 選択中写真の現像調整値を更新する。中立状態なら行を作らず、既存行があれば削除する
    // （neutral をわざわざ永続化しない）
    func updateDevelopParameters(_ parameters: DevelopParameters) {
        guard let photo = selectedPhoto else { return }
        persistDevelopParameters(parameters, forPhotoID: photo.id)
    }

    // 写真 ID を指定して現像調整値を保存する。DevelopViewModel のデバウンス保存・写真切り替え時の
    // フラッシュはこの経路を使う（selectedPhoto は保存時点で既に別写真へ切り替わっていることがあるため）。
    // currentDevelopSettings キャッシュは、対象が選択中写真のときだけ追従させる
    // フェッチは #Predicate での UUID フィルタが不安定なケースに備え、loadDevelopSettings と
    // 同じ「全件 fetch して first(where:)」パターンを踏襲する
    func persistDevelopParameters(_ parameters: DevelopParameters, forPhotoID photoID: UUID) {
        guard let context = modelContext else { return }

        if parameters.isNeutral {
            if let existing = storedDevelopSettings(forPhotoID: photoID, context: context) {
                context.delete(existing)
            }
            if currentDevelopSettings?.photoID == photoID { currentDevelopSettings = nil }
            saveOrReportError(context)
            return
        }

        let settings = developSettingsOrCreate(forPhotoID: photoID, context: context)
        do {
            try settings.setParameters(parameters)
        } catch {
            // エンコード失敗（NaN/Inf を含む調整値など）。古い値を残したまま
            // 保存成功と誤認させないよう、明示的にエラー通知して打ち切る
            self.error = ShootLogError.photoDataSaveFailed
            return
        }
        saveOrReportError(context)
    }

    // AI マスクのラスタ（子 @Model の MaskRaster）を挿す親を用意して返す。
    // persistDevelopParameters は中立の調整値では行を作らないため、マスク追加の時点では
    // まだ DevelopSettings が存在しないことがある。ラスタは親なしでは cascade 削除に
    // 乗らず孤児になるので、追加前にここで確実に作る。
    // 対象は呼び出し側（DevelopViewModel.currentPhoto）の写真 ID で指定する
    func developSettingsForMaskRaster(forPhotoID photoID: UUID) -> DevelopSettings? {
        guard let context = modelContext else { return nil }
        return developSettingsOrCreate(forPhotoID: photoID, context: context)
    }

    // 現像調整を全リセットする。resetEdits()（回転・トリミング）とは独立
    func resetDevelop() {
        guard let photo = selectedPhoto else { return }
        resetDevelop(forPhotoID: photo.id)
    }

    // 写真 ID を指定して現像調整を全リセットする（DevelopViewModel.reset 用）
    func resetDevelop(forPhotoID photoID: UUID) {
        guard let context = modelContext,
              let settings = storedDevelopSettings(forPhotoID: photoID, context: context) else { return }
        context.delete(settings)
        if currentDevelopSettings?.photoID == photoID { currentDevelopSettings = nil }
        saveOrReportError(context)
    }

    // MARK: - Private

    // DevelopSettings を取得する。なければ新規作成する。対象が選択中写真なら currentDevelopSettings にセットする。
    // currentDevelopSettings が未ロード（loadDevelopSettings を経ずに selectedPhoto が
    // 入った経路）でも photoID 重複行を作らないよう、作成前に必ずストアを引き直す
    private func developSettingsOrCreate(forPhotoID photoID: UUID, context: ModelContext) -> DevelopSettings {
        let settings: DevelopSettings
        if let stored = storedDevelopSettings(forPhotoID: photoID, context: context) {
            settings = stored
        } else {
            settings = DevelopSettings(photoID: photoID)
            context.insert(settings)
        }
        if selectedPhoto?.id == photoID { currentDevelopSettings = settings }
        return settings
    }

    // キャッシュが一致すればそれを、なければストアから引き直した DevelopSettings を返す
    private func storedDevelopSettings(forPhotoID photoID: UUID, context: ModelContext) -> DevelopSettings? {
        if let cached = currentDevelopSettings, cached.photoID == photoID { return cached }
        let all = (try? context.fetch(FetchDescriptor<DevelopSettings>())) ?? []
        return all.first(where: { $0.photoID == photoID })
    }
}
