import Foundation
import SwiftData

/// 連携アプリ（外部アプリ）の設定。ビルトインアダプターの有効/無効・表示順序と、
/// ユーザーが追加したカスタムアプリの情報を一元管理する
@Model
final class IntegrationAppSetting {
    var identifier: String          // ビルトイン: ExternalAppProtocol.id と一致 / カスタム: バンドルID
    var isEnabled: Bool
    var sortOrder: Int
    var isCustom: Bool
    var customDisplayName: String?  // isCustom時のみ使用
    var createdAt: Date

    init(
        identifier: String,
        isEnabled: Bool,
        sortOrder: Int,
        isCustom: Bool,
        customDisplayName: String? = nil
    ) {
        self.identifier = identifier
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.isCustom = isCustom
        self.customDisplayName = customDisplayName
        self.createdAt = Date()
    }
}
