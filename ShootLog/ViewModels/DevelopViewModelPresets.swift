import Foundation

// MARK: - プリセット

extension DevelopViewModel {

    /// 現在の調整値をプリセットとして保存する。
    /// - Parameter includeMasks: `true` ならマスクレイヤーも含めて保存する。既定 `false`
    ///   （放射状マスクの位置は写真ごとに意味が変わるため、既定では含めない）。
    ///   AI マスクは `includeMasks` の値によらず常に除外する（`applyPreset`参照。ラスタが
    ///   元写真にしか無く、別写真への適用時に複製できないため、保存時点で持たせない）。
    func saveCurrentAsPreset(name: String, includeMasks: Bool = false) {
        var toSave = parameters
        if !includeMasks {
            toSave.masks = []
        } else {
            toSave.masks = toSave.masks.filter { layer in
                if case .ai = layer.source { return false }
                return true
            }
        }
        content?.saveDevelopPreset(name: name, from: toSave)
    }

    func deletePreset(_ preset: DevelopPreset) {
        content?.deleteDevelopPreset(preset)
    }

    func renamePreset(_ preset: DevelopPreset, to name: String) {
        content?.renameDevelopPreset(preset, to: name)
    }

    /// プリセットの調整値を適用する。直前の状態は 1 段だけ戻せる。
    /// - Parameters:
    ///   - relative: `true` なら現在の調整値へプリセットを差分として重ねる（露出違いの
    ///     複数カットへ同じスタイルを崩さず足せる）。`false`（既定）なら丸ごと置き換える。
    ///   - includeMasks: `true` ならプリセット側のマスクも反映する。既定 `false` の場合、
    ///     `relative: true` ではプリセット側マスクを追記せず、`relative: false` では
    ///     現在のマスクレイヤーをそのまま保持する（プリセットで上書きしない）。
    ///
    ///     `includeMasks: true` でも AI マスクは常に除外する（`pasteAdjustments` と同じ理由、
    ///     プラン§3.6）。`DevelopPreset` は写真をまたいで使うのが本来の用途であり、AI マスクの
    ///     ラスタは元写真の `DevelopSettings.maskRasters` にしか存在しないため、別写真への適用時
    ///     ほぼ確実にラスタを複製できない（レビューで指摘された「fallback が実質常用パス化する」
    ///     問題）。グラデーション・輝度レンジは幾何・数値パラメータのみで写真間の意味が保たれる
    ///     ため、`.ai` だけを除いて含める。
    func applyPreset(_ preset: DevelopPreset, relative: Bool = false, includeMasks: Bool = false) {
        var presetParams = preset.parameters
        presetParams.masks = presetParams.masks.filter { layer in
            if case .ai = layer.source { return false }
            return true
        }
        if !includeMasks {
            presetParams.masks = relative ? [] : parameters.masks
        }
        // 取り込んだマスクは末尾に積まれる（relative は追記、丸ごと置き換えは全部が外来）。
        // .ai は上で除外済みなので実際にはno-opになるが、防御的に残す（§3.2参照整合性ケース3）。
        let foreignMasksFrom = includeMasks ? (relative ? parameters.masks.count : 0) : nil
        let target = relative ? parameters.applying(delta: presetParams) : presetParams
        applyReplacingParameters(target, duplicatingAIMaskRastersFrom: foreignMasksFrom)
    }
}
