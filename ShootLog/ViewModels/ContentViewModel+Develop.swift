import Foundation
import SwiftData

// RAW 現像 / 非破壊カラー編集の調整値の永続化を担当する。
// 回転・トリミング（ContentViewModel+Edit.swift）とは独立して扱う
extension ContentViewModel {
    // MARK: - Develop

    // 選択中写真の DevelopSettings を SwiftData から取得する（なければ nil）。
    // #Predicate での UUID フィルタが不安定なケースに備え、loadEditInfo と同じ
    // 「全件 fetch して first(where:)」パターンを踏襲する
    func loadDevelopSettings(for photo: Photo) {
        guard let context = modelContext else { return }
        let all = (try? context.fetch(FetchDescriptor<DevelopSettings>())) ?? []
        currentDevelopSettings = all.first(where: { $0.photoID == photo.id })
    }

    // 現像調整値を更新する。中立状態なら行を作らず、既存行があれば削除する
    // （neutral をわざわざ永続化しない）
    func updateDevelopParameters(_ parameters: DevelopParameters) {
        guard let context = modelContext, let photo = selectedPhoto else { return }

        if parameters.isNeutral {
            if let existing = currentDevelopSettings {
                context.delete(existing)
                currentDevelopSettings = nil
            }
            saveOrReportError(context)
            return
        }

        let settings = developSettingsOrCreate(for: photo, context: context)
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

    // 写真 ID を指定して現像調整値を保存する。写真切り替え時に、切り替え前の写真の
    // デバウンス保存を取りこぼさないための経路。currentDevelopSettings キャッシュには触らない
    // （対象写真は通常もう選択中ではないため）
    func persistDevelopParameters(_ parameters: DevelopParameters, forPhotoID photoID: UUID) {
        guard let context = modelContext else { return }
        let existing = ((try? context.fetch(FetchDescriptor<DevelopSettings>())) ?? [])
            .first { $0.photoID == photoID }

        if parameters.isNeutral {
            if let existing { context.delete(existing) }
            saveOrReportError(context)
            if currentDevelopSettings?.photoID == photoID { currentDevelopSettings = nil }
            return
        }

        if let existing {
            do {
                try existing.setParameters(parameters)
            } catch {
                self.error = ShootLogError.photoDataSaveFailed
                return
            }
        } else {
            let settings = DevelopSettings(photoID: photoID)
            do {
                try settings.setParameters(parameters)
            } catch {
                self.error = ShootLogError.photoDataSaveFailed
                return
            }
            context.insert(settings)
        }
        saveOrReportError(context)
    }

    // 現像調整を全リセットする。resetEdits()（回転・トリミング）とは独立
    func resetDevelop() {
        guard let context = modelContext, let settings = currentDevelopSettings else { return }
        context.delete(settings)
        currentDevelopSettings = nil
        saveOrReportError(context)
    }

    // MARK: - Private

    // DevelopSettings を取得する。なければ新規作成して currentDevelopSettings にセットする。
    // currentDevelopSettings が未ロード（loadDevelopSettings を経ずに selectedPhoto が
    // 入った経路）でも photoID 重複行を作らないよう、作成前に必ずストアを引き直す
    private func developSettingsOrCreate(for photo: Photo, context: ModelContext) -> DevelopSettings {
        if let existing = currentDevelopSettings, existing.photoID == photo.id { return existing }

        let all = (try? context.fetch(FetchDescriptor<DevelopSettings>())) ?? []
        if let stored = all.first(where: { $0.photoID == photo.id }) {
            currentDevelopSettings = stored
            return stored
        }

        let settings = DevelopSettings(photoID: photo.id)
        context.insert(settings)
        currentDevelopSettings = settings
        return settings
    }
}
