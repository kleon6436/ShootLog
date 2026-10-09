import Foundation

// 画像デコードの同時実行数を制限するアクター
// acquire で空きがなければ待機し、release で次の待機タスクへスロットを受け渡す
//
// 用途ごとにインスタンスを分ける:
// - shared: サムネイル・高解像度画像・プロキシ生成が同じデコード枠を共有する。
//   独立した枠を持つと、フォルダを開いた直後にJPEG/RAWデコードが重なって
//   IOSurfaceプールを枯渇させるため、ローカルボリュームでは共有インスタンスを使う。
// - ImageLoader のネットワークボリューム用、AILabelingGenerator / PhotoQualityDiagnosisGenerator の
//   AIバックグラウンド処理用はそれぞれ独立したインスタンスを持つ
// - visionInference: AILabelingGenerator / PhotoQualityDiagnosisGenerator の Vision 推論が共有する枠。
//   VNImageRequestHandler.perform は呼び出しスレッドを同期的に塞ぐため、両生成器の全ワーカーが
//   同時に推論すると Swift Concurrency の協調スレッドプール（コア数ぶん）を使い切り、
//   プロキシのデコードやアクター間の受け渡しが進まずAI処理が止まったように見える。
//
// キャンセル対応が必須の理由：素の withCheckedContinuation はタスクキャンセルを無視するため、
// 高速スクロールでセルが画面外に流れて .task がキャンセルされても、
// スロット待ちの継続だけがキューに残り続け、実際に表示中のセルの順番を塞いでしまう
// （スクロールし切った場所のサムネイルがいつまでも読み込まれない不具合の原因）
actor ImageDecodeThrottle {
    static let shared = ImageDecodeThrottle(
        maxConcurrent: max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
    )

    static let visionInference = ImageDecodeThrottle(maxConcurrent: 2)

    private let maxConcurrent: Int
    private var active = 0
    // 待機者の継続（ID → 継続）と到着順（ID の列）を分けて持つ。
    // キャンセル時は辞書から外すだけにし（O(1)）、順序列に残った ID は
    // release で先頭から取り出す際に読み飛ばす（遅延削除）。
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var waiterOrder: [UUID] = []
    // waiterOrder の読み出し位置。removeFirst の O(n) を避けるため添字を進め、溜まったら詰める
    private var waiterOrderHead = 0

    init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

    // スロット取得：空きがなければ resume されるまでサスペンド。
    // 待機中にタスクがキャンセルされた場合は CancellationError を投げて即座にキューから離脱する
    func acquire() async throws {
        guard active >= maxConcurrent else { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = continuation
                waiterOrder.append(id)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    // キャンセルされた待機者をキューから取り除く（スロットは消費していないので active は変更しない）
    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        // 待機者が全員いなくなったら、順序列に残るキャンセル済み ID をまとめて捨てる
        if waiters.isEmpty {
            waiterOrder.removeAll(keepingCapacity: true)
            waiterOrderHead = 0
        }
        continuation.resume(throwing: CancellationError())
    }

    // スロット解放：待機中タスクがあればスロットを転送、なければデクリメント。
    // 転送先は到着順（FIFO）で最も古い待機者。キャンセル済みの ID は読み飛ばす。
    // 辞書順で渡すと後から来た対話要求が追い越され続けて飢餓状態になり得るため、順序を保証する
    func release() async {
        while waiterOrderHead < waiterOrder.count {
            let id = waiterOrder[waiterOrderHead]
            waiterOrderHead += 1
            if let continuation = waiters.removeValue(forKey: id) {
                compactWaiterOrderIfNeeded()
                continuation.resume()
                return
            }
        }
        compactWaiterOrderIfNeeded()
        active -= 1
    }

    // 読み終えた先頭部分を順序列から取り除く。全消費時は即座に、そうでなければ半分以上が消費済みのときに詰める
    private func compactWaiterOrderIfNeeded() {
        if waiterOrderHead >= waiterOrder.count {
            waiterOrder.removeAll(keepingCapacity: true)
            waiterOrderHead = 0
        } else if waiterOrderHead > 64, waiterOrderHead * 2 > waiterOrder.count {
            waiterOrder.removeFirst(waiterOrderHead)
            waiterOrderHead = 0
        }
    }
}
