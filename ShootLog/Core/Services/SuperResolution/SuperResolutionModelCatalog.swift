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
        case "lanczos": return "superResolution.model.lanczos"
        default: return "superResolution.model.unknown"
        }
    }
}

/// 利用可能な超解像モデルのカタログ。
/// 実モデルの同梱は Phase0.5 / 0.6 で決まるため、現時点では Lanczos のみ登録する
enum SuperResolutionModelCatalog {
    static let lanczos = SuperResolutionModelDescriptor(
        id: "lanczos",
        scaleFactor: 4,
        tileLayout: .default,
        isTrainedAlgorithmicMedia: false
    )

    static let all: [SuperResolutionModelDescriptor] = [lanczos]

    static let fallback = lanczos

    static func descriptor(for id: String) -> SuperResolutionModelDescriptor? {
        all.first { $0.id == id }
    }

    /// 記述子に対応するエンジンを生成する。未知のIDは Lanczos へ解決する
    static func makeEngine(for descriptor: SuperResolutionModelDescriptor) -> any SuperResolutionEngine {
        if descriptor.id == lanczos.id {
            return LanczosSuperResolutionEngine(scaleFactor: descriptor.scaleFactor)
        }
        return CoreMLSuperResolutionEngine(descriptor: descriptor)
    }
}
