import Foundation
import FoundationModels

/// 開いたフォルダの写真を、選択写真の近傍から低優先度で説明文生成する。
@available(macOS 27, *)
actor PhotoCaptionGenerator {
    static let shared = PhotoCaptionGenerator()

    private var generationTask: Task<Void, Never>?
    private var activeBatchID: UUID?
    private var activeProgress: (@Sendable (Int, Int) -> Void)?

    /// 生成対象を受け取り、選択中インデックス近傍を優先して説明文を生成する。
    /// 既存の実行中バッチはキャンセルして置き換える。
    func start(
        urls: [URL],
        around selectedIndex: Int?,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, String?) -> Void
    ) {
        cancel()

        // モデル未有効時にonResultを呼ぶと、呼び出し元が aiCaptionFetchedAt を
        // 「生成不能」で確定させてしまい、後からApple Intelligenceを有効化しても
        // 再生成されなくなる。ここで弾いて呼び出し元に何も書かせない。
        guard SystemLanguageModel.default.isAvailable else {
            progress(0, 0)
            return
        }

        let batchID = UUID()
        activeBatchID = batchID
        activeProgress = progress
        let orderedURLs = PrioritizedBatchRunner.prioritized(urls, around: selectedIndex)
        let imageLoader = ImageLoader.shared
        generationTask = Task.detached(priority: .utility) { [weak self] in
            _ = await Self.generate(
                orderedURLs,
                imageLoader: imageLoader,
                progress: progress,
                onResult: onResult
            )
            guard !Task.isCancelled else { return }
            await self?.finish(batchID: batchID)
        }
    }

    /// 実行中バッチを打ち切る。フォルダ切替・クローズで呼ぶ。
    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        activeBatchID = nil
        activeProgress?(0, 0)
        activeProgress = nil
    }

    private func finish(batchID: UUID) {
        guard activeBatchID == batchID, !Task.isCancelled else { return }
        generationTask = nil
        activeBatchID = nil
        activeProgress = nil
    }

    private static func generate(
        _ urls: [URL],
        imageLoader: ImageLoader,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, String?) -> Void
    ) async -> Bool {
        await PrioritizedBatchRunner.run(
            items: urls,
            // Foundation Modelsのオンデバイス推論はVision分類より重いため、CPU数の1/4に絞る。
            maxWorkers: max(1, ProcessInfo.processInfo.activeProcessorCount / 4),
            progress: progress,
            process: { url in
                let outcome = await Self.caption(url, imageLoader: imageLoader)
                guard !Task.isCancelled else { return false }
                // 一時的な失敗は onResult を呼ばず、aiCaptionFetchedAt を立てさせない。
                // 次回のフォルダ読み込みで再生成の対象に残す。
                guard case .finished(let caption) = outcome else { return true }
                onResult(url, caption)
                return true
            }
        )
    }

    /// 説明文生成の結果。`finished` は結果（生成不能の `nil` を含む）を確定してよい場合、
    /// `retryLater` は混雑・タイムアウト等の一時的な失敗で、確定させずに次回へ回す場合。
    private enum CaptionOutcome {
        case finished(String?)
        case retryLater
    }

    private static func caption(
        _ url: URL,
        imageLoader: ImageLoader
    ) async -> CaptionOutcome {
        guard let image = await imageLoader.thumbnail(for: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .finished(nil)
        }

        let model = SystemLanguageModel.default
        guard model.isAvailable else { return .retryLater }

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: "写真の内容を日本語で一文に簡潔に説明してください。推測は避けてください。"
            )
            let attachment = Attachment(cgImage, orientation: nil)
            let prompt = Prompt(attachment)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return .finished(text.isEmpty ? nil : text)
        } catch let error as LanguageModelError {
            // ガードレール・拒否・非対応言語などは同じ写真で再試行しても結果が変わらないため確定させる。
            // フレームワークがコンソールへ出す "Safety guardrails were triggered" はこの経路で、
            // 写真ごとに1回だけ出て以降は再生成しない。
            switch error {
            case .rateLimited, .timeout:
                return .retryLater
            default:
                return .finished(nil)
            }
        } catch is LanguageModelSession.Error {
            // concurrentRequests 等。セッションは写真ごとに作るため一時的な競合として扱う。
            return .retryLater
        } catch is CancellationError {
            return .retryLater
        } catch {
            return .finished(nil)
        }
    }
}
