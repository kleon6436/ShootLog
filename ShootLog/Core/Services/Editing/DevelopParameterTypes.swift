import Foundation

/// トーンカーブの制御点。x/y とも正規化座標 0.0〜1.0 を想定する。
struct CurvePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// 恒等カーブ（入力 = 出力）を表す制御点列。
    static let identity: [CurvePoint] = [
        CurvePoint(x: 0, y: 0),
        CurvePoint(x: 1, y: 1)
    ]
}

/// カラー別 HSL 調整の帯域識別子。
///
/// `allCases` の順序は `DevelopParameters` の `hslHue` / `hslSaturation` / `hslLuminance`
/// 配列のインデックスと一対一で対応する（0: red 〜 7: magenta）。この順序は永続化される
/// 配列レイアウトと LUT 生成側の前提を兼ねるため、変更してはならない。
enum HSLBand: String, CaseIterable, Codable, Sendable {
    case red
    case orange
    case yellow
    case green
    case aqua
    case blue
    case purple
    case magenta

    /// 帯域の中心色相（0〜360 度）。HSL LUT 生成側が帯域の三角窓を組み立てる際に使う。
    var centerHue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 280
        case .magenta: 320
        }
    }
}

/// 現像パネルのセクション区分。各セクションを中立へ戻すリセットの単位。
enum DevelopSection: String, CaseIterable, Sendable {
    case basic
    case whiteBalance
    case color
    case toneCurve
    case hsl
    case detail
    case colorGrading
    case blackAndWhite
    case lens
    /// ローカル調整。リセットは各レイヤーの `adjustments` の中立化のみで、
    /// マスク定義（幾何・ストローク・AI ラスタ参照）は残す。
    case masks
}
