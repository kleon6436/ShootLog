import Foundation
import UniformTypeIdentifiers

/// 超解像結果の保存先を検証し、書き込みをアトミックに確定させる。
///
/// 同一性の判定にパス文字列（`standardizedFileURL` 等）を使わないこと。
/// APFS は既定で大文字小文字を区別せず、Unicode 正規化形も揃わないため、
/// 文字列比較では別パスに見える2つの URL が同じ実体を指しうる。
/// ここでは常に `URLResourceValues.fileResourceIdentifier` で実体を比較する
enum UpscaleOutputDestination {

    // MARK: - 実体の同一性

    /// ファイル実体の識別子。存在しないパスや取得できない場合は nil。
    /// シンボリックリンクに対して `fileResourceIdentifierKey` はリンク自身の識別子を返すため、
    /// 先にリンクを解決してから実体を取る（解決しないと `photos-link/out.jpg` のような
    /// 保存先が「別フォルダ」と誤判定される）
    static func fileResourceIdentifier(of url: URL) -> (any (NSCopying & NSSecureCoding & NSObjectProtocol))? {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.fileResourceIdentifierKey]) else {
            return nil
        }
        return values.fileResourceIdentifier
    }

    /// 2つの URL が同じ実体を指すか。どちらかが存在しない場合は false
    static func isSameFileSystemObject(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = fileResourceIdentifier(of: lhs),
              let right = fileResourceIdentifier(of: rhs) else { return false }
        return left.isEqual(right)
    }

    // MARK: - 防御1・防御2

    /// 保存先を検証する。原本の破壊につながる保存先は例外なく拒否する。
    /// - Parameters:
    ///   - destination: 保存先ファイルの URL
    ///   - currentFolder: 現在アプリで開いているフォルダ
    ///   - photoURLs: 現在フォルダ内の写真 URL 一覧（SwiftData から取得したものを呼び出し側が渡す）
    static func validate(destination: URL, currentFolder: URL?, photoURLs: [URL]) throws {
        // 防御1: 保存先の親ディレクトリが現在開いているフォルダと同一実体なら無条件で拒否する
        if let currentFolder {
            let parent = destination.deletingLastPathComponent()
            if isSameFileSystemObject(parent, currentFolder) {
                throw ShootLogError.superResolutionDestinationInSourceFolder
            }
        }

        // 防御2: 既存ファイルがフォルダ内の写真そのものなら拒否する（大文字小文字違いの上書きを防ぐ）
        guard let destinationIdentifier = fileResourceIdentifier(of: destination) else { return }
        for photoURL in photoURLs {
            guard let photoIdentifier = fileResourceIdentifier(of: photoURL) else { continue }
            if destinationIdentifier.isEqual(photoIdentifier) {
                throw ShootLogError.superResolutionOverwritesOriginal
            }
        }
    }

    // MARK: - 防御3（アトミック確定は行わない）
    //
    // 以前は一時ファイル（同一ディレクトリ内の隠しファイル、あるいは別ディレクトリ）へ書いてから
    // `replaceItem`/`moveItem` で確定するアトミック書き込みを試みていたが、いずれの方式も
    // サンドボックス下では失敗した。`NSSavePanel` が付与するPowerboxの権限は選択された
    // ファイルパスそのものにスコープされ、同一ディレクトリ内であっても別名のファイルを
    // 新規作成する権限までは含まれないため（ローカルディスクでは通ることがあるが、
    // SMB等のネットワーク共有では拒否される）。したがって `UpscaleExporter` は
    // 保存先へ直接書き込む方式に統一している。途中で失敗・キャンセルした場合、
    // 原本は防御1・防御2が既に守っているため危険はないが、書きかけの不完全な出力が
    // 保存先に残る可能性がある（エラー表示で利用者に伝え、再試行を促す）

    // MARK: - 防御4

    /// 拡張子から出力形式の UTType を解決する。
    /// `NSSavePanel.allowedContentTypes` を1形式へ固定するのは呼び出し側（UI層）の責務
    static func contentType(forPathExtension pathExtension: String) -> UTType? {
        UTType(filenameExtension: pathExtension.lowercased(), conformingTo: .image)
    }

    // MARK: - 防御5

    /// 既定のファイル名（拡張子なし）。原本と同名になることを避ける
    static func defaultFileName(for sourceURL: URL, scaleFactor: Int) -> String {
        "\(sourceURL.deletingPathExtension().lastPathComponent)_upscaled_\(scaleFactor)x"
    }

    // MARK: - 防御6

    /// 推定出力サイズの1.5倍を確保できるかの判定に使う係数。
    /// エンコード中は出力バイト列と一時ファイルが同時に存在しうるため余裕を持たせる
    static let requiredCapacityMultiplier = 1.5

    /// 保存先ボリュームの空き容量が推定出力サイズに対して十分かを返す。
    /// 容量を取得できない場合は書き込みを妨げないよう true を返す。
    /// SMB等一部のネットワーク共有では`volumeAvailableCapacityForImportantUsageKey`が
    /// 例外を投げずに0を返すことがある（正しく容量を報告できていないだけで、実際に
    /// 空き容量が無いわけではない）ため、0は「取得失敗」とみなし、より基本的な
    /// `volumeAvailableCapacityKey`にフォールバックする
    static func hasSufficientCapacity(at destination: URL, estimatedBytes: Int) -> Bool {
        let directory = destination.deletingLastPathComponent()
        let required = Double(estimatedBytes) * requiredCapacityMultiplier

        if let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage, available > 0 {
            return Double(available) >= required
        }

        if let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity, available > 0 {
            return Double(available) >= required
        }

        return true
    }
}
