import Foundation

// MARK: - ブラシ

extension DevelopViewModel {

    /// ブラシ半径として許容する範囲（ベース空間の正規化座標、短辺基準）。
    static let brushRadiusRange: ClosedRange<Double> = 0.005...0.3

    /// ブラシ半径の既定値。スライダーのリセット先も兼ねる。
    static let defaultBrushRadius = 0.03

    /// 点間引きのしきい値。ブラシ半径に対する比率と絶対上限の小さい方を使う。
    ///
    /// 比率だけだと大きなブラシで間引きが粗くなりすぎ、「ストローク形状の最大偏差が長辺の
    /// 0.2% 以内」という受け入れ基準を割る（落とした点は直前の採用点から高々しきい値ぶん
    /// しか離れていないので、しきい値がそのまま偏差の上界になる）。逆に絶対値だけだと
    /// 細いブラシで無駄に点が増える。
    private static let brushPointMinimumDistanceRatio = 0.15
    /// 点間引きしきい値の絶対上限（正規化座標）。受け入れ基準の 0.2% をそのまま採る。
    private static let brushPointMaximumSpacing = 0.002
    /// 1 レイヤーあたりのストローク上限。超過時は自動ラスタ化せず警告だけ出す（OQ-4）。
    private static let maxBrushStrokesPerLayer = 500
    /// ブラシ Undo の履歴保持数。
    private static let maxBrushUndoDepth = 20

    /// 直前のブラシストロークを取り消せるか。
    var canUndoBrushStroke: Bool { !brushUndoStack.isEmpty }

    /// ドラッグ開始時に呼ぶ。新しいストロークを開始する。
    /// - Parameters:
    ///   - point: ベース空間の正規化座標（最初の点）。
    ///   - layerID: ストロークを追加する対象レイヤー。
    func beginBrushStroke(at point: NormalizedPoint, layerID: UUID) {
        guard canEditMasks, parameters.masks.contains(where: { $0.id == layerID }) else { return }
        activeBrushStroke = BrushStroke(
            points: [BrushPoint(x: point.x, y: point.y)],
            radius: brushRadius,
            hardness: brushHardness,
            opacity: brushOpacity,
            isEraser: isBrushEraserMode
        )
        activeBrushLayerID = layerID
    }

    /// ドラッグ中に呼ぶ。直前の採用点から十分離れている場合だけ点を追加する。
    func continueBrushStroke(at point: NormalizedPoint) {
        guard var stroke = activeBrushStroke, let last = stroke.points.last else { return }
        let dx = point.x - last.x
        let dy = point.y - last.y
        guard (dx * dx + dy * dy).squareRoot() > Self.brushPointSpacing(forRadius: stroke.radius) else { return }
        stroke.points.append(BrushPoint(x: point.x, y: point.y))
        activeBrushStroke = stroke
    }

    /// ドラッグ終了時に呼ぶ。ストロークを確定し、対象レイヤーの `brushEdits` へ追加する。
    /// 上限に達している場合は追加せず、警告メッセージだけを出す（OQ-4: 自動ラスタ化はしない）。
    func endBrushStroke() {
        defer {
            activeBrushStroke = nil
            activeBrushLayerID = nil
        }
        guard let stroke = activeBrushStroke, let layerID = activeBrushLayerID,
              let layer = parameters.masks.first(where: { $0.id == layerID }) else { return }
        guard layer.brushEdits.count < Self.maxBrushStrokesPerLayer else {
            brushStrokeLimitReachedMessage = String(localized: "develop.mask.brush.limitReached")
            return
        }
        brushUndoStack.append((layerID: layerID, previousBrushEdits: layer.brushEdits))
        if brushUndoStack.count > Self.maxBrushUndoDepth {
            brushUndoStack.removeFirst()
        }
        updateMask(id: layerID) { $0.brushEdits.append(stroke) }
        brushStrokeLimitReachedMessage = nil
    }

    /// 直前のブラシストロークを取り消す（非永続、ViewModel 内のみ）。
    func undoLastBrushStroke() {
        guard let last = brushUndoStack.popLast() else { return }
        updateMask(id: last.layerID) { $0.brushEdits = last.previousBrushEdits }
        brushStrokeLimitReachedMessage = nil
    }

    /// 指定半径での点間引きしきい値。
    private static func brushPointSpacing(forRadius radius: Double) -> Double {
        min(brushPointMinimumDistanceRatio * max(radius, brushRadiusRange.lowerBound), brushPointMaximumSpacing)
    }

    /// 進行中ストローク・Undo 履歴・警告を捨てる。写真切り替えやマスク編集終了で呼ぶ。
    /// 別写真の `brushEdits` を誤って復元しないため、写真をまたいで持ち越してはならない。
    // DevelopViewModel.swift から参照するため internal
    func clearBrushTransientState() {
        activeBrushStroke = nil
        activeBrushLayerID = nil
        brushUndoStack.removeAll()
        brushStrokeLimitReachedMessage = nil
        isBrushPaintMode = false
    }
}
