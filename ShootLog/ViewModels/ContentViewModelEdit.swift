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

    // 90° 右回転。EditInfo がなければ新規作成する。
    // cropRect は「回転適用後の画像」基準の正規化矩形なので、回転と一緒に変換して
    // 写真上の同じ領域を切り抜いたままにする
    func rotateSelectedPhoto() {
        guard let context = modelContext, let photo = selectedPhoto else { return }
        let info = editInfoOrCreate(for: photo, context: context)
        info.rotation = (info.rotation + 90) % 360
        info.cropRect = info.cropRect.map(Self.cropRectRotatedClockwise)
        saveOrReportError(context)
    }

    // 正規化トリミング矩形（左上原点・y 下向き。ImageDevelopmentEngine.applyCrop と同じ基準）を、
    // 画像を時計回りに 90° 回したあとの座標系へ写す。
    // 点の写像は (x, y) → (1 - y, x)（MaskGeometry の 90° 回転と同じ）なので、
    // 矩形は x' = 1 - maxY、y' = minX、幅と高さが入れ替わる
    nonisolated static func cropRectRotatedClockwise(_ rect: CGRect) -> CGRect {
        CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
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
