import Foundation

/// ベース空間（回転・トリミング適用前の原寸）の正規化座標 0.0〜1.0。
/// 原点は左上、yは下向き（`EditInfo.cropRect`・SwiftUI表示座標と同じ規約）。
/// Core Image（`CIImage`、左下原点）へ渡す際はyを反転すること（`MaskImageGenerator`参照）。
struct NormalizedPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

/// ローカル調整（マスク）1 枚分の定義。
///
/// 「ベース生成子（`source`）+ ブラシ編集（`brushEdits`）」の合成として持つ。AI マスクの
/// はみ出しをブラシで消す、グラデーションの一部をブラシで足す、といった使い方を
/// 単一のレイヤーで表現するため。
///
/// マスク値の合成順（描画側の契約）:
/// ```
/// base  = source が生成するグレースケール（none は全面 0）
/// brush = brushEdits を順に適用（isEraser は減算、それ以外は加算）
/// m = clamp(base + brush, 0, 1)
/// m = isInverted ? (1 - m) : m
/// m = m * (density / 100)
/// m = feather > 0 ? gaussianBlur(m, radius) : m
/// m = m.cropped(to: baseExtent)
/// ```
struct MaskLayer: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    /// ユーザー編集可。既定は生成子から自動生成したローカライズ済みの名前。
    var name: String
    var source: MaskSource
    /// 加算・減算のブラシ編集。`source` と独立に重なるので、どの生成子にも足せる。
    var brushEdits: [BrushStroke] = []
    var isEnabled: Bool = true
    var isInverted: Bool = false
    /// マスク全体の効き（0...100）。
    var density: Double = 100
    /// ぼかし量（0...100）。描画側でガウシアン半径へ写像する。
    var feather: Double = 0
    var adjustments: LocalAdjustments
}

/// マスクのベース生成子。
///
/// 永続化形式は `type` discriminator を持つオブジェクトで、未知の `type` は
/// `.unrecognized` としてペイロードごと保持する。新しい ShootLog で増えた種別を
/// 古いビルドで開いたときに、デコード失敗で全マスクが黙って消えるのを防ぐため。
enum MaskSource: Codable, Equatable, Sendable {
    /// ベース全面 0。ブラシのみで描くマスク。
    case none
    case linearGradient(LinearGradientMask)
    case radialGradient(RadialGradientMask)
    case luminanceRange(LuminanceRangeMask)
    case ai(AIMaskReference)
    /// 未知の種別。描画時は全面 0 として扱い、再エンコードでは `raw` をそのまま書き戻す。
    case unrecognized(type: String, raw: JSONValue)
}

struct LinearGradientMask: Codable, Equatable, Sendable {
    var start: NormalizedPoint
    var end: NormalizedPoint
}

struct RadialGradientMask: Codable, Equatable, Sendable {
    var center: NormalizedPoint
    var radius: Double
    var aspectRatio: Double
    var rotationDegrees: Double
    var falloff: Double
}

/// 輝度レンジで選択するマスク。幾何を持たず、元画像の輝度だけで選択範囲が決まる。
///
/// Vision framework に空セグメンテーションの公開 API が無いため、「画面上部・高輝度」のような
/// 選択を線形グラデーションとの重ねで作るための土台として用意している（OQ-9）。
struct LuminanceRangeMask: Codable, Equatable, Sendable {
    /// 選択する輝度範囲の下限（0...1）。
    var lowerBound: Double
    /// 選択する輝度範囲の上限（0...1）。`lowerBound <= upperBound` を期待するが、
    /// 保存データが崩れていても描画側は例外を投げない（`MaskImageGenerator` 参照）。
    var upperBound: Double
    /// 境界のぼかし具合（0...100）。0 で急峻、100 で滑らか。
    var smoothness: Double
}

/// AI マスクのラスタ（子 `@Model` の `MaskRaster`）への参照。
struct AIMaskReference: Codable, Equatable, Sendable {
    var rasterID: UUID
    var kind: AIMaskKind
    var instanceIndices: [Int]
    var visionRevision: Int
    /// 焼き込み解像度のヒント。UI 表示と再生成要否の判定に使い、描画には使わない
    /// （描画に効く長辺は `MaskRaster.longEdge` が正）。
    var bakedLongEdge: Int
    var bakedAt: Date
}

enum AIMaskKind: String, Codable, Equatable, Sendable {
    case foregroundSubject
    case person
}

struct BrushStroke: Codable, Equatable, Sendable {
    var points: [BrushPoint]
    var radius: Double
    var hardness: Double
    var opacity: Double
    var isEraser: Bool
}

/// ベース空間の正規化座標で表したブラシの通過点。
struct BrushPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

/// マスク内側へ適用する調整値。`DevelopParameters` のフィールド部分集合。
///
/// 幾何系（レンズ補正・回転・トリミング）は持たない。局所段では既に幾何変形済みの
/// 画像を扱うため。`masks` 相当のフィールドも持たない（再帰の停止条件）。
struct LocalAdjustments: Codable, Equatable, Sendable {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var clarity: Double = 0
    var structure: Double = 0
    var sharpness: Double = 0
    var luminanceNoiseReduction: Double = 0
    var colorNoiseReduction: Double = 0
    /// 相対オフセットの色温度（-100...100）。局所段の入力は既にグローバル WB 適用済みの
    /// 画像なので、絶対 Kelvin や as-shot 基準は意味を持たない。`DevelopParameters` の
    /// レガシー相対経路と同じ意味論で解釈する。
    var temperature: Double = 0
    /// 相対オフセットの色かぶり（-100...100）。`temperature` と同じ意味論。
    var tint: Double = 0
}

// MARK: - MaskSource Codable

extension MaskSource {

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    /// `type` discriminator の値。永続化されるため変更してはならない。
    private enum TypeName {
        static let none = "none"
        static let linearGradient = "linearGradient"
        static let radialGradient = "radialGradient"
        static let luminanceRange = "luminanceRange"
        static let ai = "ai"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case TypeName.none:
            self = .none
        case TypeName.linearGradient:
            self = .linearGradient(try container.decode(LinearGradientMask.self, forKey: .payload))
        case TypeName.radialGradient:
            self = .radialGradient(try container.decode(RadialGradientMask.self, forKey: .payload))
        case TypeName.luminanceRange:
            self = .luminanceRange(try container.decode(LuminanceRangeMask.self, forKey: .payload))
        case TypeName.ai:
            self = .ai(try container.decode(AIMaskReference.self, forKey: .payload))
        default:
            // 未知の種別。オブジェクト全体を値として保持し、再エンコードで書き戻す。
            self = .unrecognized(type: type, raw: try JSONValue(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        if case .unrecognized(_, let raw) = self {
            var single = encoder.singleValueContainer()
            try single.encode(raw)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(TypeName.none, forKey: .type)
        case .linearGradient(let mask):
            try container.encode(TypeName.linearGradient, forKey: .type)
            try container.encode(mask, forKey: .payload)
        case .radialGradient(let mask):
            try container.encode(TypeName.radialGradient, forKey: .type)
            try container.encode(mask, forKey: .payload)
        case .luminanceRange(let mask):
            try container.encode(TypeName.luminanceRange, forKey: .type)
            try container.encode(mask, forKey: .payload)
        case .ai(let reference):
            try container.encode(TypeName.ai, forKey: .type)
            try container.encode(reference, forKey: .payload)
        case .unrecognized:
            break   // 上で処理済み
        }
    }
}
