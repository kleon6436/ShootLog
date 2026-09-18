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
        let orderedURLs = Self.prioritizedURLs(urls, around: selectedIndex)
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

    private static func prioritizedURLs(_ urls: [URL], around selectedIndex: Int?) -> [URL] {
        guard let selectedIndex, urls.indices.contains(selectedIndex) else { return urls }

        var result: [URL] = []
        result.reserveCapacity(urls.count)
        for distance in 0..<urls.count {
            let next = selectedIndex + distance
            if urls.indices.contains(next) {
                result.append(urls[next])
            }

            guard distance > 0 else { continue }
            let previous = selectedIndex - distance
            if urls.indices.contains(previous) {
                result.append(urls[previous])
            }
        }
        return result
    }

    private static func generate(
        _ urls: [URL],
        imageLoader: ImageLoader,
        progress: @escaping @Sendable (Int, Int) -> Void,
        onResult: @escaping @Sendable (URL, String?) -> Void
    ) async -> Bool {
        let total = urls.count
        guard total > 0 else {
            progress(0, 0)
            return true
        }

        guard !Task.isCancelled else { return false }
        let firstURL = urls[0]
        let firstResult = await Self.caption(firstURL, imageLoader: imageLoader)
        guard !Task.isCancelled else { return false }
        onResult(firstURL, firstResult)

        var completed = 1
        progress(completed, total)
        var nextIndex = 1
        // Foundation Modelsのオンデバイス推論はVision分類より重いため、CPU数の1/4に絞る。
        let workerCount = min(
            total - nextIndex,
            max(1, ProcessInfo.processInfo.activeProcessorCount / 4)
        )

        guard workerCount > 0 else { return true }

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<workerCount {
                let url = urls[nextIndex]
                nextIndex += 1
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return false }
                    let result = await Self.caption(url, imageLoader: imageLoader)
                    guard !Task.isCancelled else { return false }
                    onResult(url, result)
                    await Task.yield()
                    return true
                }
            }

            while let _ = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }

                completed += 1
                progress(completed, total)
                if nextIndex < total {
                    let url = urls[nextIndex]
                    nextIndex += 1
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return false }
                        let result = await Self.caption(url, imageLoader: imageLoader)
                        guard !Task.isCancelled else { return false }
                        onResult(url, result)
                        await Task.yield()
                        return true
                    }
                }
            }
        }

        guard !Task.isCancelled else { return false }
        return completed == total
    }

    private static func caption(
        _ url: URL,
        imageLoader: ImageLoader
    ) async -> String? {
        guard let image = await imageLoader.thumbnail(for: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: "写真の内容を日本語で一文に簡潔に説明してください。推測は避けてください。"
            )
            let attachment = Attachment(cgImage, orientation: nil)
            let prompt = Prompt(attachment)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
