import Foundation
// `Array.move(fromOffsets:toOffset:)`（`List.onMove` と同じ並べ替え意味論）のため。
import SwiftUI

// MARK: - マスク（ローカル調整）

extension DevelopViewModel {

    /// 線形グラデーションのマスクレイヤーを 1 枚追加し、選択状態にする。
    /// プレビューが出ていない間は何もしない（§1.5.2）。
    /// - Returns: 追加したレイヤーの ID。追加しなかった場合は `nil`。
    @discardableResult
    func addLinearGradientMask() -> UUID? {
        guard canEditMasks else { return nil }
        let layer = MaskLayer(
            id: UUID(),
            name: String(format: String(localized: "develop.mask.defaultName"), Int64(parameters.masks.count + 1)),
            source: .linearGradient(LinearGradientMask(
                start: NormalizedPoint(x: 0.3, y: 0.5),
                end: NormalizedPoint(x: 0.7, y: 0.5)
            )),
            adjustments: LocalAdjustments()
        )
        var updated = parameters
        updated.masks.append(layer)
        parameters = updated
        selectedMaskLayerID = layer.id
        return layer.id
    }

    /// 放射状グラデーションのマスクレイヤーを 1 枚追加し、選択状態にする。
    /// - Returns: 追加したレイヤーの ID。追加しなかった場合は `nil`。
    @discardableResult
    func addRadialGradientMask() -> UUID? {
        guard canEditMasks else { return nil }
        let layer = MaskLayer(
            id: UUID(),
            name: String(format: String(localized: "develop.mask.defaultName"), Int64(parameters.masks.count + 1)),
            source: .radialGradient(RadialGradientMask(
                center: NormalizedPoint(x: 0.5, y: 0.5),
                radius: 0.3,
                aspectRatio: 1.0,
                rotationDegrees: 0,
                falloff: 50
            )),
            adjustments: LocalAdjustments()
        )
        var updated = parameters
        updated.masks.append(layer)
        parameters = updated
        selectedMaskLayerID = layer.id
        return layer.id
    }

    /// 輝度レンジのマスクレイヤーを 1 枚追加し、選択状態にする。
    /// 既定は「明るい部分」の選択（空マスクの代替という主用途に寄せた初期値）。
    /// - Returns: 追加したレイヤーの ID。追加しなかった場合は `nil`。
    @discardableResult
    func addLuminanceRangeMask() -> UUID? {
        guard canEditMasks else { return nil }
        let layer = MaskLayer(
            id: UUID(),
            name: String(format: String(localized: "develop.mask.defaultName"), Int64(parameters.masks.count + 1)),
            source: .luminanceRange(LuminanceRangeMask(
                lowerBound: 0.6,
                upperBound: 1.0,
                smoothness: 30
            )),
            adjustments: LocalAdjustments()
        )
        var updated = parameters
        updated.masks.append(layer)
        parameters = updated
        selectedMaskLayerID = layer.id
        return layer.id
    }

    /// ブラシだけで描くマスクレイヤーを 1 枚追加し、選択したうえでペイントモードへ入る。
    /// ベースは全面 0（`.none`）なので、追加直後は何も塗られていない状態から始まる。
    /// - Returns: 追加したレイヤーの ID。追加しなかった場合は `nil`。
    @discardableResult
    func addBrushMask() -> UUID? {
        guard canEditMasks else { return nil }
        let layer = MaskLayer(
            id: UUID(),
            name: String(
                format: String(localized: "develop.mask.brush.defaultName"),
                Int64(parameters.masks.count + 1)
            ),
            source: .none,
            adjustments: LocalAdjustments()
        )
        var updated = parameters
        updated.masks.append(layer)
        parameters = updated
        selectedMaskLayerID = layer.id
        isBrushPaintMode = true
        return layer.id
    }

    /// 指定したマスクレイヤーを削除する。
    /// プレビューの有無でゲートしない。レンダー失敗などで `previewImage` が消えた状態から
    /// 抜け出す唯一の手段が削除のため。
    func removeMask(id: UUID) {
        guard parameters.masks.contains(where: { $0.id == id }) else { return }
        var updated = parameters
        updated.masks.removeAll { $0.id == id }
        parameters = updated
        if selectedMaskLayerID == id { selectedMaskLayerID = nil }
        // 消えたレイヤーを指す Undo エントリ・進行中ストロークは復元先が無い。
        brushUndoStack.removeAll { $0.layerID == id }
        if activeBrushLayerID == id {
            activeBrushStroke = nil
            activeBrushLayerID = nil
        }
    }

    /// マスクレイヤーの表示順を並べ替える。index 0 が最下層のまま、配列の並びを直接操作する。
    /// `List.onMove` のシグネチャに合わせてある。
    func moveMasks(from source: IndexSet, to destination: Int) {
        guard canEditMasks else { return }
        var updated = parameters
        updated.masks.move(fromOffsets: source, toOffset: destination)
        guard updated != parameters else { return }
        parameters = updated
    }

    /// 指定したマスクレイヤーをその場で書き換える。`parameters` 経由で代入するため、
    /// 再描画と永続化は既存の didSet が予約する。
    func updateMask(id: UUID, _ transform: (inout MaskLayer) -> Void) {
        guard let index = parameters.masks.firstIndex(where: { $0.id == id }) else { return }
        var updated = parameters
        transform(&updated.masks[index])
        guard updated != parameters else { return }
        parameters = updated
    }
}
