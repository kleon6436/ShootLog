import Foundation

// フォルダ履歴のセキュリティスコープブックマークを解決し、フォルダの実体が今も存在するかを判定する。
// 削除済みフォルダや未マウントのネットワークボリュームを履歴一覧から隠すために使う
enum FolderAvailabilityChecker {
    // 1件あたりの判定に許容する最大待ち時間（秒）
    static let timeoutSeconds: Double = 2.0

    // ブックマークからフォルダの存在を確認する。
    // タイムアウトした場合は true（存在するものとして扱う）を返し、
    // 低速なネットワークボリュームの履歴を誤って隠さないようにする
    static func isAvailable(bookmark: Data) async -> Bool {
        let gate = ResumeGate()
        return await withCheckedContinuation { continuation in
            // 実際のファイルI/Oはメインスレッドを塞がないよう detached で行う。
            // タイムアウト側が先に応答した場合も、このTaskは完了まで走り切って結果だけ捨てられる
            Task.detached(priority: .utility) {
                let result = performCheck(bookmark: bookmark)
                if await gate.claim() { continuation.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                if await gate.claim() { continuation.resume(returning: true) }
            }
        }
    }

    // MARK: - Private

    // ブックマーク解決とファイル存在確認。呼び出し元がメインスレッド外であることを前提とする
    private static func performCheck(bookmark: Data) -> Bool {
        var isStale = false
        // .withoutUI / .withoutMounting は、未マウントのネットワークボリュームに対して
        // マウントダイアログや接続待ちが発生するのを防ぐために必須
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return false }

        // サンドボックス下ではスコープを開始しないと存在確認が偽陰性になる
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    // 判定結果とタイムアウトのどちらか一方だけが継続を再開できるようにするゲート
    private actor ResumeGate {
        private var hasResumed = false

        func claim() -> Bool {
            guard !hasResumed else { return false }
            hasResumed = true
            return true
        }
    }
}
