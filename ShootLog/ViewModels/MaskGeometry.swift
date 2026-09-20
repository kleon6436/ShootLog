import Foundation

/// マスク編集オーバーレイの座標変換。
///
/// マスク幾何は「ベース空間」＝レンズ補正後・回転前・トリミング前の画像を基準とした
/// 正規化座標 0...1（左上原点、y は下方向）で保持する。`EditInfo.cropRect` と SwiftUI の
/// 表示座標に原点の取り方を合わせてあり、`NormalizedPoint` もこの約束で解釈する。
///
/// 一方マスク編集中に画面へ出ているのは `DevelopViewModel.previewImage`（回転・トリミング
/// 焼き込み済み）を素の `.aspectRatio(contentMode: .fit)` で表示したものなので、次の 4 段を
/// 往復できる必要がある。
///
/// ```
/// 表示点 → aspect-fit レターボックス枠内の正規化座標（previewImage.size 基準）
///       → un-crop（cropRect の逆写像）
///       → un-rotate（quarter-turn の逆）
///       → ベース空間の正規化座標
/// ```
///
/// 表示枠の算出には **`previewImage` の実サイズだけ**を使い、`cropRect` からの解析的な再構成に
/// 依存しない。`ImageDevelopmentEngine.applyCrop` が `.integral` で丸めるため、解析的に求めた
/// 表示サイズは実画像と 1px 単位でずれるが、実サイズを真実とすればこのずれが表示枠に入らない。
///
/// レターボックス外の表示点は**クランプせず線形に外挿する**。確定済みトリミングの外側に端点を
/// 持つグラデーションのハンドルを保持・操作できる必要があるため（プラン §1.5.3）。0...1 に
/// 収めたい呼び出し側は `clampedBasePoint(fromDisplay:)` を使う。
struct MaskGeometry: Equatable, Sendable {
    /// 画面に出ている現像プレビューの実サイズ。
    let previewImageSize: CGSize
    /// プレビューを載せているコンテナのサイズ（SwiftUI 座標系）。
    let containerSize: CGSize
    /// 時計回りの回転角。0 / 90 / 180 / 270 に正規化済み。
    let rotation: Int
    /// 正規化トリミング矩形（左上原点、回転後の画像基準）。`nil` はトリミングなし。
    let cropRect: CGRect?
    /// コンテナ座標系での表示画像の矩形（レターボックスを除いた領域）。
    let imageFrame: CGRect

    /// ベース空間（回転・トリミング前）のピクセルアスペクト比（幅/高さ）。
    ///
    /// 放射状マスクの楕円・円形ハンドルは正規化座標だけでは非正方形画像で歪む
    /// （`MaskImageGenerator` は extent の実ピクセル短辺を基準に半径を換算するため）。
    /// `previewImageSize`（回転・トリミング済み）を回転・トリミングの逆写像で
    /// ベース空間のピクセル寸法へ戻し、その比率だけを使う（実ピクセル値そのものは不要）。
    ///
    /// `ImageDevelopmentEngine` は「回転 → トリミング」の順で適用し、`cropRect` は
    /// 回転後の画像基準の正規化矩形（このファイル冒頭のdocstring参照）。逆算は
    /// **先にcropRectで割ってポスト回転・プレクロップのサイズへ戻し、
    /// そのあとで回転の90/270スワップを行う**必要がある（適用順の逆順）。
    var baseAspectRatio: CGFloat {
        let uncropped: CGSize
        if let cropRect, cropRect.width > 0, cropRect.height > 0 {
            uncropped = CGSize(
                width: previewImageSize.width / cropRect.width,
                height: previewImageSize.height / cropRect.height
            )
        } else {
            uncropped = previewImageSize
        }
        return rotation % 180 != 0
            ? uncropped.height / uncropped.width
            : uncropped.width / uncropped.height
    }

    /// 表示サイズが未確定（プレビュー未到着・レイアウト前）の場合は `nil` を返す。
    /// マスク編集はプレビューが出るまで無効化される（プラン §1.5.2）ので、呼び出し側は
    /// `nil` をそのまま「編集不可」として扱ってよい。
    init?(previewImageSize: CGSize, containerSize: CGSize, rotation: Int, cropRect: CGRect?) {
        guard previewImageSize.width > 0, previewImageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0,
              previewImageSize.width.isFinite, previewImageSize.height.isFinite,
              containerSize.width.isFinite, containerSize.height.isFinite else {
            return nil
        }
        self.previewImageSize = previewImageSize
        self.containerSize = containerSize
        self.rotation = ((rotation % 360) + 360) % 360

        if let cropRect, cropRect.width > 0, cropRect.height > 0,
           cropRect.minX.isFinite, cropRect.minY.isFinite,
           cropRect.width.isFinite, cropRect.height.isFinite,
           cropRect != CGRect(x: 0, y: 0, width: 1, height: 1) {
            self.cropRect = cropRect
        } else {
            self.cropRect = nil
        }

        let scale = min(containerSize.width / previewImageSize.width,
                        containerSize.height / previewImageSize.height)
        let width = previewImageSize.width * scale
        let height = previewImageSize.height * scale
        self.imageFrame = CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// 表示点がレターボックスを除いた画像領域の内側にあるか。
    func containsDisplayPoint(_ point: CGPoint) -> Bool {
        imageFrame.contains(point)
    }

    /// ベース空間（回転・トリミング前、`BrushMaskRasterizer` の半径解釈と同じ「短辺 = 1」の
    /// 正規化）の距離 1 単位に対応する、表示座標系（コンテナ座標系）の pt 数。
    ///
    /// `brushRadius` はベース空間の正規化座標で持つため、トリミングでズームインした写真では
    /// ベース空間の短辺と表示中プレビューの短辺の拡大率が一致しない。カーソル円の見た目を
    /// 実際に塗られる範囲と一致させるため、`baseAspectRatio` と同じ「短辺 = 1 のピクセル空間」
    /// 経由でクロップ・回転の逆写像を通してから換算する（レビュー指摘）。
    /// x/y 方向でスケールが異なりうる（非正方形画像・矩形トリミング）ため平均を近似値として返す。
    var displayPointsPerBaseShortEdgeUnit: CGFloat {
        let baseRatio = baseAspectRatio.isFinite && baseAspectRatio > 0 ? baseAspectRatio : 1
        let pixelWidth = baseRatio >= 1 ? baseRatio : 1
        let pixelHeight = baseRatio >= 1 ? 1 : 1 / baseRatio

        let center = displayPoint(fromBase: NormalizedPoint(x: 0.5, y: 0.5))
        let alongX = displayPoint(fromBase: NormalizedPoint(x: 0.5 + 1 / pixelWidth, y: 0.5))
        let alongY = displayPoint(fromBase: NormalizedPoint(x: 0.5, y: 0.5 + 1 / pixelHeight))

        let scaleX = hypot(alongX.x - center.x, alongX.y - center.y)
        let scaleY = hypot(alongY.x - center.x, alongY.y - center.y)
        return (scaleX + scaleY) / 2
    }

    /// 表示点（コンテナ座標系）をベース空間の正規化座標へ変換する。
    /// 画像領域の外側はクランプせず外挿するため、0...1 の外へ出ることがある。
    func basePoint(fromDisplay point: CGPoint) -> NormalizedPoint {
        let display = normalizedInImageFrame(point)
        let rotated = unapplyCrop(display)
        return unapplyRotation(rotated)
    }

    /// `basePoint(fromDisplay:)` の結果を 0...1 へクランプした版。
    func clampedBasePoint(fromDisplay point: CGPoint) -> NormalizedPoint {
        let base = basePoint(fromDisplay: point)
        return NormalizedPoint(x: base.x.clampedToUnitRange, y: base.y.clampedToUnitRange)
    }

    /// ベース空間の正規化座標を表示点（コンテナ座標系）へ変換する。
    /// `basePoint(fromDisplay:)` の逆写像で、0...1 の外側も同じ線形写像で外挿する。
    func displayPoint(fromBase point: NormalizedPoint) -> CGPoint {
        let rotated = applyRotation(point)
        let display = applyCrop(rotated)
        return CGPoint(
            x: imageFrame.minX + display.x * imageFrame.width,
            y: imageFrame.minY + display.y * imageFrame.height
        )
    }

    // MARK: - 段ごとの写像

    private func normalizedInImageFrame(_ point: CGPoint) -> NormalizedPoint {
        NormalizedPoint(
            x: Double((point.x - imageFrame.minX) / imageFrame.width),
            y: Double((point.y - imageFrame.minY) / imageFrame.height)
        )
    }

    /// 表示（トリミング後）正規化 → 回転後・トリミング前の正規化。
    private func unapplyCrop(_ point: NormalizedPoint) -> NormalizedPoint {
        guard let cropRect else { return point }
        return NormalizedPoint(
            x: Double(cropRect.minX) + point.x * Double(cropRect.width),
            y: Double(cropRect.minY) + point.y * Double(cropRect.height)
        )
    }

    /// 回転後・トリミング前の正規化 → 表示（トリミング後）正規化。
    private func applyCrop(_ point: NormalizedPoint) -> NormalizedPoint {
        guard let cropRect else { return point }
        return NormalizedPoint(
            x: (point.x - Double(cropRect.minX)) / Double(cropRect.width),
            y: (point.y - Double(cropRect.minY)) / Double(cropRect.height)
        )
    }

    /// 回転後の正規化 → ベース空間の正規化。`ImageDevelopmentEngine.applyRotation`（時計回り）の逆。
    private func unapplyRotation(_ point: NormalizedPoint) -> NormalizedPoint {
        switch rotation {
        case 90: NormalizedPoint(x: point.y, y: 1 - point.x)
        case 180: NormalizedPoint(x: 1 - point.x, y: 1 - point.y)
        case 270: NormalizedPoint(x: 1 - point.y, y: point.x)
        default: point
        }
    }

    /// ベース空間の正規化 → 回転後の正規化（時計回り）。
    private func applyRotation(_ point: NormalizedPoint) -> NormalizedPoint {
        switch rotation {
        case 90: NormalizedPoint(x: 1 - point.y, y: point.x)
        case 180: NormalizedPoint(x: 1 - point.x, y: 1 - point.y)
        case 270: NormalizedPoint(x: point.y, y: 1 - point.x)
        default: point
        }
    }
}

private extension Double {
    var clampedToUnitRange: Double { min(1, max(0, self)) }
}
