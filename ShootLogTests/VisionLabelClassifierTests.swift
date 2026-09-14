import AppKit
import Foundation
import Testing

@testable import ShootLog

struct VisionLabelClassifierTests {

    @Test func 代表的なidentifierをカテゴリへ分類する() {
        #expect(VisionLabelClassifier.category(for: "dog") == .animal)
        #expect(VisionLabelClassifier.category(for: "birthday_cake") == .food)
        #expect(VisionLabelClassifier.category(for: "living_room") == .indoor)
        #expect(VisionLabelClassifier.category(for: "street_sign") == .text)
        #expect(VisionLabelClassifier.category(for: "balloon_hotair") == .vehicle)
    }

    @Test func 未知のidentifierはunknownになる() {
        #expect(VisionLabelClassifier.category(for: "identifier_not_in_vision_revision_1") == .unknown)
    }

    @Test func AI画像プロバイダはフォルダ写真とエクスポート済みiCloud写真にプロキシを使い未エクスポート写真は軽量サムネイルへフォールバック() async throws {
        let folderURL = URL(fileURLWithPath: "/tmp/folder-photo.jpg")
        let exportedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-labeling-exported-\(UUID().uuidString).jpg")
        let unexportedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-labeling-unexported-\(UUID().uuidString).jpg")
        try Data().write(to: exportedURL)
        defer { try? FileManager.default.removeItem(at: exportedURL) }

        let proxyURLs = URLRecorder()
        let fallbackRequests = ThumbnailRequestRecorder()
        let provider = DefaultAILabelingImageProvider(
            proxyImageLoader: { url in
                await proxyURLs.record(url)
                return NSImage(size: NSSize(width: 1, height: 1))
            },
            photosLibraryThumbnailLoader: { localIdentifier, targetSize in
                await fallbackRequests.record(localIdentifier: localIdentifier, targetSize: targetSize)
                return NSImage(size: NSSize(width: 1, height: 1))
            }
        )

        _ = await provider.thumbnail(for: AILabelingTarget(url: folderURL, localIdentifier: nil))
        _ = await provider.thumbnail(for: AILabelingTarget(url: exportedURL, localIdentifier: "icloud-exported"))
        _ = await provider.thumbnail(for: AILabelingTarget(url: unexportedURL, localIdentifier: "icloud-unexported"))

        #expect(await proxyURLs.values() == [folderURL, exportedURL])
        #expect(await fallbackRequests.values() == [
            ThumbnailRequest(
                localIdentifier: "icloud-unexported",
                targetSize: CGSize(width: 480, height: 480)
            )
        ])
    }
}

private actor URLRecorder {
    private var recordedURLs: [URL] = []

    func record(_ url: URL) {
        recordedURLs.append(url)
    }

    func values() -> [URL] {
        recordedURLs
    }
}

private struct ThumbnailRequest: Equatable, Sendable {
    let localIdentifier: String
    let targetSize: CGSize
}

private actor ThumbnailRequestRecorder {
    private var requests: [ThumbnailRequest] = []

    func record(localIdentifier: String, targetSize: CGSize) {
        requests.append(ThumbnailRequest(localIdentifier: localIdentifier, targetSize: targetSize))
    }

    func values() -> [ThumbnailRequest] {
        requests
    }
}
