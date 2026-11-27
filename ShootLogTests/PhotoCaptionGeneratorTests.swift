import Foundation
import Testing

@testable import ShootLog

@MainActor
struct PhotoCaptionGeneratorTests {

    // テスト中に利用可否を切り替えられるようにする（modelNotReady → available の再判定を確かめるため）
    private final class FakeAvailabilityProvider: CaptionModelAvailabilityProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var value: CaptionModelAvailability

        init(_ value: CaptionModelAvailability) {
            self.value = value
        }

        func set(_ newValue: CaptionModelAvailability) {
            lock.withLock { value = newValue }
        }

        func availability() -> CaptionModelAvailability {
            lock.withLock { value }
        }
    }

    private final class ResultRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var resultURLs: [URL] = []
        private var progressValues: [(Int, Int)] = []

        var results: [URL] { lock.withLock { resultURLs } }
        var progress: [(Int, Int)] { lock.withLock { progressValues } }

        func recordResult(_ url: URL) { lock.withLock { resultURLs.append(url) } }
        func recordProgress(_ done: Int, _ total: Int) { lock.withLock { progressValues.append((done, total)) } }
    }

    // MARK: - 生成器単体

    // onResult が呼ばれない回帰があってもテスト全体が止まらないよう時間制限を付ける
    @Test(.timeLimit(.minutes(1)))
    func availableModelStartsGenerationAndReportsResult() async {
        // 存在しないファイルはサムネイルが取れず「生成不能（nil）」で確定するため、実モデルを呼ばずに完了まで追える
        let url = URL(fileURLWithPath: "/tmp/photo-caption-available-\(UUID().uuidString).jpg")
        let generator = PhotoCaptionGenerator(availabilityProvider: FakeAvailabilityProvider(.available))

        let (stream, continuation) = AsyncStream<(URL, String?)>.makeStream()
        let didStart = await generator.start(
            urls: [url],
            around: 0,
            progress: { _, _ in },
            onResult: { resultURL, caption in continuation.yield((resultURL, caption)) }
        )

        #expect(didStart)
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next()
        #expect(result?.0 == url)
        #expect(result?.1 == nil)
        await generator.cancel()
        continuation.finish()
    }

    @Test(arguments: [CaptionModelAvailability.modelNotReady, .unavailable])
    func unavailableModelSkipsWithoutReportingResults(_ availability: CaptionModelAvailability) async {
        let url = URL(fileURLWithPath: "/tmp/photo-caption-skip.jpg")
        let generator = PhotoCaptionGenerator(availabilityProvider: FakeAvailabilityProvider(availability))
        let recorder = ResultRecorder()

        let didStart = await generator.start(
            urls: [url],
            around: 0,
            progress: { done, total in recorder.recordProgress(done, total) },
            onResult: { resultURL, _ in recorder.recordResult(resultURL) }
        )

        #expect(!didStart)
        // onResult を呼ばないことで、呼び出し元に aiCaptionFetchedAt を確定させない
        #expect(recorder.results.isEmpty)
        #expect(recorder.progress.map(\.0) == [0])
        #expect(recorder.progress.map(\.1) == [0])
    }

    @Test func modelNotReadyIsRecheckedOnNextStart() async {
        let provider = FakeAvailabilityProvider(.modelNotReady)
        let generator = PhotoCaptionGenerator(availabilityProvider: provider)
        let url = URL(fileURLWithPath: "/tmp/photo-caption-not-ready-\(UUID().uuidString).jpg")

        let firstStart = await generator.start(urls: [url], around: 0, progress: { _, _ in }, onResult: { _, _ in })
        #expect(!firstStart)

        provider.set(.available)
        let secondStart = await generator.start(urls: [url], around: 0, progress: { _, _ in }, onResult: { _, _ in })
        #expect(secondStart)
        await generator.cancel()
    }

    // MARK: - ContentViewModel からの呼び出し

    @Test(arguments: [CaptionModelAvailability.modelNotReady, .unavailable])
    func folderLoadDoesNotRecordCaptionWhenModelIsUnavailable(_ availability: CaptionModelAvailability) async {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo-caption-content-skip.jpg"))
        let content = ContentViewModel()
        content.photos = [photo]
        content.photoCaptionGenerator = PhotoCaptionGenerator(
            availabilityProvider: FakeAvailabilityProvider(availability)
        )

        let token = content.beginPhotoCaption()
        let didStart = await content.startPhotoCaption(photoIndex: [photo.fileURL: 0], token: token)

        #expect(!didStart)
        // 失敗も記録しないため、次回の読み込みで再び生成対象になる
        #expect(photo.aiCaptionFetchedAt == nil)
        #expect(photo.aiCaptionText == nil)
    }

    @Test func folderLoadStartsCaptionWhenModelIsAvailable() async {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo-caption-content-\(UUID().uuidString).jpg"))
        let content = ContentViewModel()
        content.photos = [photo]
        let generator = PhotoCaptionGenerator(availabilityProvider: FakeAvailabilityProvider(.available))
        content.photoCaptionGenerator = generator

        let token = content.beginPhotoCaption()
        let didStart = await content.startPhotoCaption(photoIndex: [photo.fileURL: 0], token: token)

        #expect(didStart)
        await generator.cancel()
    }
}
