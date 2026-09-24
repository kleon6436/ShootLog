import Foundation

/// フォルダ読み込み時のバックグラウンド生成（プレビュー・AI被写体認識・AI画質診断・キャプション）が
/// 共有する処理ループ。選択写真の近傍を優先して並べ、先頭 1 件を単独で処理してから残りを並列に処理する。
///
/// 各生成器の違い（結果の通知・キャッシュ整理・ワーカー数）は呼び出し側の closure に閉じ込める。
/// 実行中バッチの開始・キャンセルの状態管理は各生成器（actor）側が持つ。
enum PrioritizedBatchRunner {

    /// 選択中インデックスから近い順（同距離なら後方→前方）に並べ替える。
    /// インデックスが無い・範囲外ならそのまま返す。
    static func prioritized<Item>(_ items: [Item], around selectedIndex: Int?) -> [Item] {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return items }

        var result: [Item] = []
        result.reserveCapacity(items.count)
        for distance in 0..<items.count {
            let next = selectedIndex + distance
            if items.indices.contains(next) {
                result.append(items[next])
            }

            guard distance > 0 else { continue }
            let previous = selectedIndex - distance
            if items.indices.contains(previous) {
                result.append(items[previous])
            }
        }
        return result
    }

    /// `items` を先頭から処理する。先頭 1 件は単独で処理し（選択写真を最優先で仕上げるため）、
    /// 残りは最大 `maxWorkers` 件を並列に処理する。
    ///
    /// - Parameters:
    ///   - progress: 1 件完了するたびに `(完了数, 総数)` で呼ぶ。対象が 0 件なら `(0, 0)`。
    ///   - onCompleted: 並列処理中、1 件完了するたびに完了数を渡して呼ぶ（定期的なキャッシュ整理など）。
    ///   - onFinished: キャンセルされずに最後まで処理したときに 1 回だけ呼ぶ。対象が 0 件のときは呼ばない。
    ///   - process: 1 件を処理する。結果の通知もこの中で行い、途中でキャンセルされたら `false` を返す。
    /// - Returns: キャンセルされずに全件を処理したか。
    @discardableResult
    static func run<Item: Sendable>(
        items: [Item],
        maxWorkers: Int,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onCompleted: (@Sendable (Int) async -> Void)? = nil,
        onFinished: (@Sendable () async -> Void)? = nil,
        process: @escaping @Sendable (Item) async -> Bool
    ) async -> Bool {
        let total = items.count
        guard total > 0 else {
            progress(0, 0)
            return true
        }

        guard !Task.isCancelled else { return false }
        _ = await process(items[0])
        guard !Task.isCancelled else { return false }

        var completed = 1
        progress(completed, total)
        var nextIndex = 1
        let workerCount = min(total - nextIndex, maxWorkers)

        guard workerCount > 0 else {
            await onFinished?()
            return true
        }

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<workerCount {
                let item = items[nextIndex]
                nextIndex += 1
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return false }
                    let didProcess = await process(item)
                    await Task.yield()
                    return didProcess
                }
            }

            while let _ = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }

                completed += 1
                progress(completed, total)
                await onCompleted?(completed)

                if nextIndex < total {
                    let item = items[nextIndex]
                    nextIndex += 1
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return false }
                        let didProcess = await process(item)
                        await Task.yield()
                        return didProcess
                    }
                }
            }
        }

        guard !Task.isCancelled else { return false }
        await onFinished?()
        return completed == total
    }
}
