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

    // MARK: - 防御3

    /// 一時ファイルの URL を作る。書き込みは必ずここへ行い、`commit` で確定させる
    static func makeTemporaryURL(pathExtension: String) -> URL {
        let name = UUID().uuidString
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        return pathExtension.isEmpty ? url : url.appendingPathExtension(pathExtension)
    }

    /// 一時ファイルを保存先へアトミックに置き換える。
    /// 途中でクラッシュしても保存先が中途半端な内容になることはない
    static func commit(temporaryURL: URL, to destination: URL) throws {
        do {
            try FileManager.default.replaceItem(
                at: destination,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [],
                resultingItemURL: nil
            )
        } catch {
            // 保存先が未作成の場合 replaceItem は失敗するため、移動で確定させる
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw ShootLogError.superResolutionExportFailed
            }
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
            } catch {
                throw ShootLogError.superResolutionExportFailed
            }
        }
    }

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
    /// 容量を取得できない場合は書き込みを妨げないよう true を返す
    static func hasSufficientCapacity(at destination: URL, estimatedBytes: Int) -> Bool {
        let directory = destination.deletingLastPathComponent()
        guard let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage else { return true }

        let required = Double(estimatedBytes) * requiredCapacityMultiplier
        return Double(available) >= required
    }
}
