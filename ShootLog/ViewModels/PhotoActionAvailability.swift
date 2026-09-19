import Foundation

/// 写真1枚に対して実行できる操作の可否をまとめた値型。
/// グリッドの右クリックメニュー・編集ツールバー・書き出し導線が同じ判定を共有するために使う。
///
/// `ModelContainer` も `ContentViewModel` も必要としない純粋な値型にしてあるため、
/// View 側で組み立ててもテストから直接検証できる。
/// `[any ExternalAppProtocol]` は `Equatable` でないため配列そのものは保持せず、
/// 判定に必要な `hasExternalApps` だけを受け取る。
struct PhotoActionAvailability {
    let photo: Photo
    /// 利用可能な外部アプリが1つ以上あるか
    let hasExternalApps: Bool

    init(photo: Photo, hasExternalApps: Bool = false) {
        self.photo = photo
        self.hasExternalApps = hasExternalApps
    }

    /// ユーザーのフォルダ配下に原本ファイルがあるか。
    /// iCloud写真ライブラリの写真が持つのは `icloud-import-v2/` のエクスポートキャッシュ
    /// （上限超過で eviction される一時パス）だけなので false になる。
    /// 現像・書き出し・パスコピーはいずれもこの条件を共有する
    var hasLocalOriginalFile: Bool {
        photo.phAssetLocalIdentifier == nil
    }

    /// 外部アプリで開けるか。iCloud写真も実行時にエクスポートしてから開くため、
    /// 判定は「開ける外部アプリがあるか」だけに依存する
    var canOpenExternally: Bool {
        hasExternalApps
    }

    /// ファイルパスをパスボードへコピーできるか。
    /// iCloud写真のパスは eviction 対象の一時キャッシュを指すため、コピーさせない
    var canCopyPath: Bool {
        hasLocalOriginalFile
    }

    /// 現像タブを開けるか。iCloud写真のRAW現像・書き出しは現時点でスコープ外
    var canDevelop: Bool {
        hasLocalOriginalFile
    }
}
