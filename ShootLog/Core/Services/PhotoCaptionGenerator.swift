import Foundation
import FoundationModels

/// 説明文生成に使うオンデバイスモデルの利用可否。
enum CaptionModelAvailability: Sendable, Equatable {
    case available
    /// Apple Intelligence の有効化直後やモデルのダウンロード中など、待てば使えるようになる状態。
    case modelNotReady
    /// 非対応機種・Apple Intelligence 無効など、こちらからは解消できない状態。
    case unavailable
}

/// モデルの利用可否を返す。テストで状態を固定できるようにプロトコル経由で注入する。
protocol CaptionModelAvailabilityProviding: Sendable {
    func availability() -> CaptionModelAvailability
}

struct SystemCaptionModelAvailabilityProvider: CaptionModelAvailabilityProviding {
    static let shared = SystemCaptionModelAvailabilityProvider()

    func availability() -> CaptionModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unavailable
        }
    }
}

/// 開いたフォルダの写真を、選択写真の近傍から低優先度で説明文生成する。
actor PhotoCaptionGenerator {
    static let shared = PhotoCaptionGenerator()

    private let availabilityProvider: any CaptionModelAvailabilityProviding

    private var generationTask: Task<Void, Never>?
    private var activeBatchID: UUID?
    private var activeProgress: (@Sendable (Int, Int) -> Void)?

    init(availabilityProvider: any CaptionModelAvailabilityProviding = SystemCaptionModelAvailabilityProvider.shared) {
        self.availabilityProvider = availabilityProvider
    }

    /// 生成対象を受け取り、選択中インデックス近傍を優先して説明文を生成する。
    /// 既存の実行中バッチはキャンセルして置き換える。
    /// - Returns: 生成を開始した場合は `true`。モデルが使えずスキップした場合は `false`。
    @discardableResult
    func start(
        urls: [URL],
        around selectedIndex: Int?,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, String?) -> Void
    ) -> Bool {
        cancel()

        // モデルが使えないときに onResult を呼ぶと、呼び出し元が aiCaptionFetchedAt を
        // 「生成不能」で確定させてしまい、後から使えるようになっても再生成されなくなる。
        // ここで弾いて呼び出し元に何も書かせない。利用可否は start のたびに取り直すため、
        // modelNotReady は次のフォルダ/iCloud読み込みで自然に再判定される。
        // それ以外の利用不可はユーザーが解消できないことが多いため、ログ・UIも出さずに黙ってスキップする
        guard availabilityProvider.availability() == .available else {
            progress(0, 0)
            return false
        }

        let batchID = UUID()
        activeBatchID = batchID
        activeProgress = progress
        let orderedURLs = PrioritizedBatchRunner.prioritized(urls, around: selectedIndex)
        let imageLoader = ImageLoader.shared
        let availabilityProvider = availabilityProvider
        generationTask = Task.detached(priority: .utility) { [weak self] in
            _ = await Self.generate(
                orderedURLs,
                imageLoader: imageLoader,
                availabilityProvider: availabilityProvider,
                progress: progress,
                onResult: onResult
            )
            guard !Task.isCancelled else { return }
            await self?.finish(batchID: batchID)
        }
        return true
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
        availabilityProvider: any CaptionModelAvailabilityProviding,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, String?) -> Void
    ) async -> Bool {
        await PrioritizedBatchRunner.run(
            items: urls,
            // Foundation Modelsのオンデバイス推論はVision分類より重いため、CPU数の1/4に絞る。
            maxWorkers: max(1, ProcessInfo.processInfo.activeProcessorCount / 4),
            progress: progress,
            process: { url in
                let outcome = await Self.caption(
                    url,
                    imageLoader: imageLoader,
                    availabilityProvider: availabilityProvider
                )
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
        imageLoader: ImageLoader,
        availabilityProvider: any CaptionModelAvailabilityProviding
    ) async -> CaptionOutcome {
        // バッチ途中で Apple Intelligence が無効化された場合に備えて写真ごとに確かめ直す。
        // 使えないと分かっている写真のサムネイルをデコードしないよう、画像の取得より先に判定する
        guard availabilityProvider.availability() == .available else { return .retryLater }
        guard let image = await imageLoader.thumbnail(for: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .finished(nil)
        }

        let model = SystemLanguageModel.default

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
