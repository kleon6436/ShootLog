import CoreGraphics
import SwiftData
import Foundation

// 非破壊編集（回転・トリミング）を担当する
extension ContentViewModel {
    // MARK: - Edit

    // 選択中写真の EditInfo を SwiftData から取得する（なければ nil）
    func loadEditInfo(for photo: Photo) {
        guard let context = modelContext else { return }
        let all = (try? context.fetch(FetchDescriptor<EditInfo>())) ?? []
        currentEditInfo = all.first(where: { $0.photoID == photo.id })
    }

    // 90° 右回転。EditInfo がなければ新規作成する
    func rotateSelectedPhoto() {
        guard let context = modelContext, let photo = selectedPhoto else { return }
        let info = editInfoOrCreate(for: photo, context: context)
        info.rotation = (info.rotation + 90) % 360
        saveOrReportError(context)
    }

    // トリミング矩形を保存して crop モードを終了する
    func setCropRect(_ rect: CGRect?) {
        guard let context = modelContext, let photo = selectedPhoto else { return }
        let info = editInfoOrCreate(for: photo, context: context)
        info.cropRect = rect
        saveOrReportError(context)
        isCropMode = false
    }

    func toggleCropMode() {
        guard selectedPhoto != nil else { return }
        isCropMode.toggle()
    }

    // EditInfo を削除して編集を全リセットする
    func resetEdits() {
        guard let context = modelContext, let info = currentEditInfo else { return }
        context.delete(info)
        currentEditInfo = nil
        isCropMode = false
        saveOrReportError(context)
    }

    // MARK: - Private

    // EditInfo を取得する。なければ新規作成して currentEditInfo にセットする。
    // currentEditInfo が別の写真のものである（loadEditInfo を経ずに selectedPhoto が
    // 入れ替わった経路）場合に他の写真の編集情報を書き換えないよう、
    // developSettingsOrCreate と同じく photoID を検証してから返す。
    // 現行のproduction経路（selectPhoto が必ず loadEditInfo を呼ぶ）では起きないが、
    // 将来の誤用に対する防御として持たせる。
    // フェッチは #Predicate での UUID フィルタが不安定なケースに備え、loadEditInfo と同じ
    // 「全件 fetch して first(where:)」パターンを踏襲する
    private func editInfoOrCreate(for photo: Photo, context: ModelContext) -> EditInfo {
        if let existing = currentEditInfo, existing.photoID == photo.id { return existing }

        let all = (try? context.fetch(FetchDescriptor<EditInfo>())) ?? []
        if let stored = all.first(where: { $0.photoID == photo.id }) {
            currentEditInfo = stored
            return stored
        }

        let info = EditInfo(photoID: photo.id)
        context.insert(info)
        currentEditInfo = info
        return info
    }
}
