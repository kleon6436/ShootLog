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
    ///   `regenerateAIMask`/`refineAIMask` が「無関係な操作で `maskLayers.count` が
    ///   たまたま増えた」ことを成功と誤判定しないよう、カウント比較ではなく戻り値で成否を伝える
    ///   （レビュー指摘: AI 生成中に他種別マスクを追加されるとレイヤーを誤削除しうる）。
    @discardableResult
    func addAIMask(kind: AIMaskKind, clickPoint: NormalizedPoint? = nil) async -> UUID? {
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
        guard let settings = content?.developSettingsForMaskRaster() else { return nil }

        let rasterID = UUID()
        let raster = MaskRaster(id: rasterID, pngData: result.pngData, longEdge: result.longEdge)
        settings.maskRasters.append(raster)

        let nameFormat = switch kind {
        case .person: String(localized: "develop.mask.ai.personName")
        case .foregroundSubject: String(localized: "develop.mask.ai.subjectName")
        }
        let layer = MaskLayer(
            id: UUID(),
            name: String(format: nameFormat, Int64(parameters.masks.count + 1)),
            source: .ai(AIMaskReference(
                rasterID: rasterID,
                kind: kind,
                instanceIndices: result.instanceIndices,
                visionRevision: Self.currentVisionRevision,
                bakedLongEdge: result.longEdge,
                bakedAt: .now
            )),
            adjustments: LocalAdjustments()
        )
        var updated = parameters
        updated.masks.append(layer)
        parameters = updated
        selectedMaskLayerID = layer.id
        return layer.id
    }

    /// このレイヤーが現行の Vision 世代と異なる世代で焼き込まれているか。UI の再生成導線の表示条件。
    func maskNeedsRegeneration(_ layer: MaskLayer) -> Bool {
        guard case .ai(let reference) = layer.source else { return false }
        if reference.visionRevision != Self.currentVisionRevision { return true }
        // visionRevisionは一致していても、参照先のMaskRasterが存在しない状態
        // （他写真のプリセットを誤って流用した等の防御的ケース）も再生成対象として扱う。
        // これが無いと、ユーザーはマスクが無効である理由に気づく手段が無い（レビュー指摘）。
        guard let settings = content?.currentDevelopSettings else { return false }
        return !settings.maskRasters.contains { $0.id == reference.rasterID }
    }

    /// AI マスクレイヤーを同じ種別で作り直す。ユーザーが明示的に呼んだときだけ実行し、
    /// `visionRevision` 不一致を検知して自動で作り直すことはしない（§3.2）。
    ///
    /// クリック位置は永続化していないため全インスタンス再検出になる。生成に失敗した場合は
    /// 元のレイヤーを残す（失敗して何も無くなる状態を作らない）。
    func regenerateAIMask(id: UUID) async {
        guard let layer = maskLayers.first(where: { $0.id == id }),
              case .ai(let reference) = layer.source else { return }
        // カウント比較ではなく戻り値の ID で成否判定する（レビュー指摘: 生成中に他種別の
        // マスクが追加されると `maskLayers.count` の増減だけでは誤判定する）。
        guard await addAIMask(kind: reference.kind) != nil else { return }
        removeMask(id: id)
    }
}
