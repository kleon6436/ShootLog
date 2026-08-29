import Foundation
import SwiftData

/// RAW 現像 / 非破壊カラー編集の調整値を写真ごとに永続化するモデル。
///
/// 調整値は `DevelopParameters` を JSON エンコードした Data ブロブとして保持する。
/// フィールド構成が将来変わっても旧レコードを読めるよう、blob のデコード失敗時は
/// `.neutral` へフォールバックし、`schemaVersion` で blob 形式の世代を管理する。
/// 元ファイルは変更しない（`EditInfo` と同じ非破壊方針）。
@Model
final class DevelopSettings {
    /// 対応する `Photo.id`。`EditInfo` と同じく明示的な UUID 一致で紐付ける。
    var photoID: UUID = UUID()
    /// `JSONEncoder().encode(DevelopParameters)` の結果。
    var parametersData: Data = DevelopSettings.encodedNeutral()
    /// blob 形式の世代。現在 1。将来 blob レイアウトを変えた際の分岐ガードに使う。
    var schemaVersion: Int = 1
    /// 調整値を最後に更新した時刻。
    var updatedAt: Date = Date.now

    /// 中立状態のレコードを生成する。
    init(photoID: UUID) {
        self.photoID = photoID
        self.parametersData = DevelopSettings.encodedNeutral()
        self.schemaVersion = 1
        self.updatedAt = .now
    }

    /// 保持している調整値。
    ///
    /// get はデコード失敗（破損 blob）時に `.neutral` を返す。
    /// set はエンコードに成功した場合のみ blob と `updatedAt` を進める。エンコード失敗時は
    /// 無言で古い値を残すと呼び出し側が保存成功と誤認するため、失敗を伝えたい経路では
    /// `setParameters(_:)` を使うこと（この setter は失敗を握り潰す簡便版）。
    var parameters: DevelopParameters {
        get {
            (try? JSONDecoder().decode(DevelopParameters.self, from: parametersData)) ?? .neutral
        }
        set {
            try? setParameters(newValue)
        }
    }

    /// 調整値を差し替える。エンコードに失敗した場合は `throw` し、blob と `updatedAt` は変更しない。
    func setParameters(_ newValue: DevelopParameters) throws {
        let encoded = try DevelopSettings.encode(newValue)
        parametersData = encoded
        updatedAt = .now
    }

    /// `DevelopParameters` を JSON エンコードする。NaN / Inf を含む場合など `JSONEncoder` は throw する。
    static func encode(_ parameters: DevelopParameters) throws -> Data {
        try JSONEncoder().encode(parameters)
    }

    /// 中立状態の `DevelopParameters` をエンコードした Data。
    /// init と get のフォールバックで共用する。中立値は必ずエンコードできるが、
    /// 万一失敗しても空 Data を返し、その場合 get 側で `.neutral` に倒れる。
    static func encodedNeutral() -> Data {
        (try? encode(DevelopParameters.neutral)) ?? Data()
    }
}
