import Foundation
import SwiftData

/// 名前付きの現像調整プリセット。写真をまたいで適用できる。
///
/// `DevelopSettings` と同じく `DevelopParameters` を JSON エンコードした Data ブロブで保持し、
/// デコード失敗時は `.neutral` へフォールバックする。特定の写真には紐付かない（グローバル）。
@Model
final class DevelopPreset {
    /// 安定した識別子。並べ替えや管理 UI での参照に使う。
    var id: UUID = UUID()
    /// 表示名。
    var name: String = ""
    /// `JSONEncoder().encode(DevelopParameters)` の結果。
    var parametersData: Data = DevelopPreset.encodedNeutral()
    /// blob 形式の世代。現在 1。
    var schemaVersion: Int = 1
    /// 作成日時。
    var createdAt: Date = Date.now
    /// メニューでの並び順。新規は末尾に付ける。
    var sortIndex: Int = 0

    init(name: String, parameters: DevelopParameters, sortIndex: Int) {
        self.id = UUID()
        self.name = name
        self.parametersData = (try? DevelopPreset.encode(parameters)) ?? DevelopPreset.encodedNeutral()
        self.schemaVersion = 1
        self.createdAt = .now
        self.sortIndex = sortIndex
    }

    /// 保持している調整値。デコード失敗時は `.neutral`。
    var parameters: DevelopParameters {
        get { (try? JSONDecoder().decode(DevelopParameters.self, from: parametersData)) ?? .neutral }
        set { try? setParameters(newValue) }
    }

    /// 調整値を差し替える。エンコード失敗時は `throw` し、blob は変更しない。
    func setParameters(_ newValue: DevelopParameters) throws {
        parametersData = try DevelopPreset.encode(newValue)
    }

    static func encode(_ parameters: DevelopParameters) throws -> Data {
        try JSONEncoder().encode(parameters)
    }

    static func encodedNeutral() -> Data {
        (try? encode(DevelopParameters.neutral)) ?? Data()
    }
}
