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
//
// キャンセル対応が必須の理由：素の withCheckedContinuation はタスクキャンセルを無視するため、
// 高速スクロールでセルが画面外に流れて .task がキャンセルされても、
// スロット待ちの継続だけがキューに残り続け、実際に表示中のセルの順番を塞いでしまう
// （スクロールし切った場所のサムネイルがいつまでも読み込まれない不具合の原因）
actor ImageDecodeThrottle {
    static let shared = ImageDecodeThrottle(
        maxConcurrent: max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
    )

    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

    // スロット取得：空きがなければ resume されるまでサスペンド。
    // 待機中にタスクがキャンセルされた場合は CancellationError を投げて即座にキューから離脱する
    func acquire() async throws {
        guard active >= maxConcurrent else { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    // キャンセルされた待機者をキューから取り除く（スロットは消費していないので active は変更しない）
    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    // スロット解放：待機中タスクがあればスロットを転送、なければデクリメント。
    // 転送先は辞書の先頭要素で、到着順（FIFO）は保証しない
    func release() async {
        if let (id, continuation) = waiters.first {
            waiters.removeValue(forKey: id)
            continuation.resume()
        } else {
            active -= 1
        }
    }
}
