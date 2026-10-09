import AppKit
import Foundation

// MARK: - AI マスク

extension DevelopViewModel {

    /// マスク生成ロジック（前処理・Vision モデル）の世代番号。生成結果の見えが変わる変更を
    /// 入れたら上げる。不一致のレイヤーには UI が再生成導線を出す（黙って作り直さない、§3.2）。
    static let currentVisionRevision = 1

    /// AI マスクのラスタを焼き込む長辺。`AIMaskReference.bakedLongEdge` として記録する（OQ-3）。
    private static let aiMaskBakedLongEdge = 1_024
    /// Vision へ渡すプレビューの最小長辺。`SubjectMaskGenerating` が要求する
    /// 「最小辺 512px 以上」を通常のアスペクト比で満たすための下限。
    private static let visionInputMinimumLongEdge: CGFloat = 1_024

    /// AI 被写体 / 人物マスクを追加し、選択状態にする。
    ///
    /// - Parameters:
    ///   - kind: 被写体マスクか人物マスクか。
    ///   - clickPoint: ベース空間の正規化座標（左上原点・y 下向き）。`nil` なら検出された
    ///     全インスタンスを使う。
    ///
    /// `.person` は「人物なし」を戻り値で判定できない（`SubjectMaskGenerating` の注記。
    /// 実測で confidence は常に 1.0）。したがって生成できたマスクは必ずレイヤーとして提示し、
    /// 不適切かどうかの判断は `removeMask(id:)` でユーザーに委ねる。
    /// - Returns: 生成に成功した新規レイヤーの ID。失敗・早期リターン時は `nil`。
    ///   カウント比較ではなく戻り値で成否を伝える（レビュー指摘: AI 生成中に他種別マスクを
    ///   追加されると `maskLayers.count` の増減だけでは誤判定しうる）。
    @discardableResult
    func addAIMask(kind: AIMaskKind, clickPoint: NormalizedPoint? = nil) async -> UUID? {
        guard let reference = await generateAIMaskRaster(kind: kind, clickPoint: clickPoint) else { return nil }

        let nameFormat = switch kind {
        case .person: String(localized: "develop.mask.ai.personName")
        case .foregroundSubject: String(localized: "develop.mask.ai.subjectName")
        }
        let layer = MaskLayer(
            id: UUID(),
            name: String(format: nameFormat, Int64(parameters.masks.count + 1)),
            source: .ai(reference),
            adjustments: LocalAdjustments()
        )
        var updated = parameters
        updated.masks.append(layer)
        parameters = updated
        selectedMaskLayerID = layer.id
        return layer.id
    }

    /// Vision でマスクを生成し、ラスタを `currentPhoto` の `DevelopSettings.maskRasters` へ挿して
    /// その参照を返す。レイヤーへの反映は呼び出し側が行う（新規追加か既存レイヤーの差し替えか）。
    /// 失敗時は `aiMaskGenerationFailureMessage` を立てて `nil` を返す。
    private func generateAIMaskRaster(kind: AIMaskKind, clickPoint: NormalizedPoint?) async -> AIMaskReference? {
        guard canEditMasks, !isGeneratingAIMask, let photo = currentPhoto else { return nil }

        isGeneratingAIMask = true
        aiMaskGenerationFailureMessage = nil
        defer { isGeneratingAIMask = false }

        // Vision 入力はベース空間（回転・トリミング前）で作る。表示空間を渡すと
        // マスクの正規化座標が `MaskImageGenerator` の基準とずれる（§1.5）。
        let params = parameters
        let target = max(
            PhotoImageViewModel.targetMaxPixelSize(for: displaySize),
            Self.visionInputMinimumLongEdge
        )
        guard let source = await engine.renderPreview(
            url: photo.fileURL,
            parameters: params,
            targetMaxPixelSize: target,
            rotation: 0,
            cropRect: nil,
            previewColorSpace: nil,
            useRAWParameterMapping: rawMappingActive,
            usesManualLensCorrection: shouldApplyManualLensCorrection(params),
            usesToneMaskedColorGrading: toneMaskedColorGradingActive,
            asShotWhiteBalance: toneMaskedColorGradingActive ? asShotWhiteBalance : nil,
            maskRasters: resolvedMaskRasters(for: params)
        ) else {
            aiMaskGenerationFailureMessage = String(localized: "develop.mask.ai.generationFailed")
            return nil
        }

        // Vision の正規化座標は左下原点・y 上向き。`NormalizedPoint` とは y が逆。
        let visionClickPoint = clickPoint.map { CGPoint(x: $0.x, y: 1 - $0.y) }
        guard let result = await maskGenerator.generateMask(
            for: source,
            kind: kind,
            clickPoint: visionClickPoint,
            targetLongEdge: Self.aiMaskBakedLongEdge
        ) else {
            aiMaskGenerationFailureMessage = switch kind {
            case .person: String(localized: "develop.mask.ai.noPersonFound")
            case .foregroundSubject: String(localized: "develop.mask.ai.noSubjectFound")
            }
            return nil
        }
        // 生成中に写真が切り替わっていたら、別写真のラスタを貼らない。
        guard currentPhoto?.id == photo.id else { return nil }

        // DevelopSettingsの確保はVision成功後に行う。Vision失敗・写真切替などの早期returnで
        // 中立な空行が永続的に残るのを防ぐため（updateDevelopParametersの「中立状態では
        // 行を作らない」という不変条件に反しないようにする。レビュー指摘）。
        guard let settings = content?.developSettingsForMaskRaster(forPhotoID: photo.id) else { return nil }

        let rasterID = UUID()
        let raster = MaskRaster(id: rasterID, pngData: result.pngData, longEdge: result.longEdge)
        settings.maskRasters.append(raster)

        return AIMaskReference(
            rasterID: rasterID,
            kind: kind,
            instanceIndices: result.instanceIndices,
            visionRevision: Self.currentVisionRevision,
            bakedLongEdge: result.longEdge,
            bakedAt: .now
        )
    }

    /// このレイヤーが現行の Vision 世代と異なる世代で焼き込まれているか。UI の再生成導線の表示条件。
    func maskNeedsRegeneration(_ layer: MaskLayer) -> Bool {
        guard case .ai(let reference) = layer.source else { return false }
        if reference.visionRevision != Self.currentVisionRevision { return true }
        // visionRevisionは一致していても、参照先のMaskRasterが存在しない状態
        // （他写真のプリセットを誤って流用した等の防御的ケース）も再生成対象として扱う。
        // これが無いと、ユーザーはマスクが無効である理由に気づく手段が無い（レビュー指摘）。
        guard let settings = currentPhotoDevelopSettings else { return false }
        return !settings.maskRasters.contains { $0.id == reference.rasterID }
    }

    /// AI マスクレイヤーを同じ種別で作り直す。ユーザーが明示的に呼んだときだけ実行し、
    /// `visionRevision` 不一致を検知して自動で作り直すことはしない（§3.2）。
    ///
    /// - Parameter clickPoint: ベース空間の正規化座標。指定するとその位置のインスタンスで作り直す
    ///   （オーバーレイのクリックによる絞り込み）。`nil` なら全インスタンス再検出
    ///   （クリック位置は永続化していないため、再生成ボタンからはこちらになる）。
    ///
    /// レイヤーは差し替えずに `source`（ラスタ参照）だけをその場で書き換える。新規レイヤーを足して
    /// 旧レイヤーを消す方式だと、ローカル調整・反転・濃度・ぼかし・名前・ブラシ編集・重なり順が
    /// すべて初期化されてしまうため。生成に失敗した場合は元のレイヤーを残す（失敗して何も無くなる
    /// 状態を作らない）。旧ラスタは参照が外れ、写真を離れる時点の GC で回収される（Undo 用に即時削除しない）。
    func regenerateAIMask(id: UUID, clickPoint: NormalizedPoint? = nil) async {
        guard let layer = maskLayers.first(where: { $0.id == id }),
              case .ai(let reference) = layer.source else { return }
        guard let regenerated = await generateAIMaskRaster(kind: reference.kind, clickPoint: clickPoint) else { return }
        // 生成中にレイヤーが削除・種別変更されていたら書き戻さない（新ラスタは孤児として GC される）。
        // 並べ替えられていても ID で引き直すので、重なり順は生成完了時点のものが保たれる。
        guard let index = parameters.masks.firstIndex(where: { $0.id == id }),
              case .ai = parameters.masks[index].source else { return }
        var updated = parameters
        updated.masks[index].source = .ai(regenerated)
        parameters = updated
        selectedMaskLayerID = id
    }
}
