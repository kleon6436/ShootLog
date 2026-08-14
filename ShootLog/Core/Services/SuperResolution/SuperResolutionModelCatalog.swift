import Foundation

/// 超解像モデル1件のメタデータ。`id` は設定へ永続化するためASCII固定とし、
/// 表示名は `displayName` へ分離する
struct SuperResolutionModelDescriptor: Sendable, Identifiable, Equatable {
    let id: String
    let scaleFactor: Int
    let tileLayout: TileLayout
    /// AI生成物としてのマーカー（IPTC DigitalSourceType）を出力に付与するか。
    /// 補間アルゴリズムは学習済みモデルではないため付与しない
    let isTrainedAlgorithmicMedia: Bool

    var displayName: LocalizedStringResource {
        switch id {
        case SuperResolutionModelCatalog.lanczosID: return "superResolution.model.lanczos"
        default: return "superResolution.model.unknown"
        }
    }
}

/// 利用可能な超解像モデルのカタログ。
/// `all` は同梱済みのCore MLモデルを列挙する。従来方式(Lanczos)は学習済みモデルではなく
/// 任意倍率を組み立てられる補間アルゴリズムのため、`all` には含めず `lanczos(scaleFactor:)` で作る
enum SuperResolutionModelCatalog {
    static let lanczosID = "lanczos"

    /// 4倍モデル(realesr-general-x4v3, SRVGGNetCompact)。
    /// `id` は `Resources/Models/<id>.mlpackage` のファイル名と一致させる
    /// （`CoreMLSuperResolutionEngine.bundledModelURL(for:)` が名前で探すため）
    static let realesrganX4 = SuperResolutionModelDescriptor(
        id: "realesrgan",
        scaleFactor: 4,
        tileLayout: .scaled(by: 4),
        isTrainedAlgorithmicMedia: true
    )

    /// 2倍モデル(RealESRGAN_x2plus, RRDBNet)。128px入力・8pxオーバーラップは実測のうえ
    /// 既定値のまま確定した（継ぎ目の段差は検出されず、オーバーラップを増やしても改善しない。
    /// 実測値は `Tools/CoreML/README.md` の「2倍モデルの実測結果」を参照）
    static let realesrganX2 = SuperResolutionModelDescriptor(
        id: "realesrgan_x2plus",
        scaleFactor: 2,
        tileLayout: .scaled(by: 2),
        isTrainedAlgorithmicMedia: true
    )

    static let all: [SuperResolutionModelDescriptor] = [realesrganX4, realesrganX2]

    static func descriptor(for id: String) -> SuperResolutionModelDescriptor? {
        all.first { $0.id == id }
    }

    /// 指定倍率に対応する同梱モデル。対応モデルが無い倍率では nil を返す
    static func aiModel(forScaleFactor scaleFactor: Int) -> SuperResolutionModelDescriptor? {
        all.first { $0.scaleFactor == scaleFactor }
    }

    /// 従来方式(Lanczos)の記述子。補間アルゴリズムのため任意倍率で組み立てられる
    static func lanczos(scaleFactor: Int) -> SuperResolutionModelDescriptor {
        SuperResolutionModelDescriptor(
            id: lanczosID,
            scaleFactor: scaleFactor,
            tileLayout: .scaled(by: scaleFactor),
            isTrainedAlgorithmicMedia: false
        )
    }

    /// 記述子に対応するエンジンを生成する
    static func makeEngine(for descriptor: SuperResolutionModelDescriptor) -> any SuperResolutionEngine {
        if descriptor.id == lanczosID {
            return LanczosSuperResolutionEngine(scaleFactor: descriptor.scaleFactor)
        }
        return CoreMLSuperResolutionEngine(descriptor: descriptor)
    }
}
