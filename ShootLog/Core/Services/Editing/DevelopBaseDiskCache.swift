import CoreGraphics
import CryptoKit
import Foundation

/// 現像 Stage A の中立ベースを PNG ロスレスで永続化するディスクキャッシュ。
///
/// 読み書きはいずれも同期 I/O なので、呼び出し側（`ImageDevelopmentEngine`）が detached タスクから使う。
/// メモリ LRU と書き込みタスクの管理は engine 側に残している。
struct DevelopBaseDiskCache: Sendable {
    let directory: URL
    let maxBytes: Int

    /// ディスク上のファイル名に使うキー。原本パス・更新時刻・サイズバケットから決める。
    static func key(path: String, modifiedAt: TimeInterval, sizeBucket: Int) -> String {
        let source = "\(path)|\(modifiedAt)|\(sizeBucket)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func read(forKey key: String) -> CGImage? {
        ImageFileCache.read(forKey: key, extensions: ["png"], in: directory)
    }

    /// 書き込みに成功したときだけ容量上限までの削除を行う。
    func write(_ image: CGImage, forKey key: String) {
        ImageFileCache.prepare(directory: directory, extensions: ["png"])
        guard ImageFileCache.write(
            image,
            type: "public.png" as CFString,
            to: ImageFileCache.fileURL(forKey: key, extension: "png", in: directory)
        ) else { return }
        ImageFileCache.evict(in: directory, maxBytes: maxBytes)
    }

    /// 中断ファイルを掃除し、容量上限まで削除する。
    func warmUp() {
        ImageFileCache.prepare(directory: directory, extensions: ["png"])
        ImageFileCache.evict(in: directory, maxBytes: maxBytes)
    }

    func removeAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
