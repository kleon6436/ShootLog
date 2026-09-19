import AppKit
import Foundation
import Testing

@testable import ShootLog

@MainActor
struct ContentViewModelQualityDiagnosisTests {

    @Test func imageResolutionFailureKeepsPhotoEligibleForRediagnosis() async {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/quality-diagnosis-unresolved.jpg"))
        let content = ContentViewModel()
        content.photos = [photo]
        content.qualityDiagnosisGenerator = PhotoQualityDiagnosisGenerator(
            imageProvider: StubQualityImageProvider(providesImage: false),
            diagnoser: StubQualityDiagnoser(result: nil)
        )

        let token = content.beginAIQualityDiagnosis()
        await content.startAIQualityDiagnosis(token: token, around: nil)

        #expect(await wait { content.aiQualityDiagnosisCompletedCount == 1 })
        #expect(photo.aiDiagnosisFetchedAt == nil)
        #expect(photo.aiDiagnosisSchemaVersion == nil)
    }

    @Test func partialVisionResultStillMarksPhotoAsDiagnosed() async {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/quality-diagnosis-partial.jpg"))
        let content = ContentViewModel()
        content.photos = [photo]
        // Vision が一部スコアしか返せなかったケース（画像自体は解決できている）
        let partial = PhotoQualityDiagnosis(
            aestheticsScore: nil,
            isUtility: false,
            faceQualityScore: nil,
            exposureBias: -0.5,
            sharpnessScore: nil,
            compositionOffsetScore: nil
        )
        content.qualityDiagnosisGenerator = PhotoQualityDiagnosisGenerator(
            imageProvider: StubQualityImageProvider(providesImage: true),
            diagnoser: StubQualityDiagnoser(result: partial)
        )

        let token = content.beginAIQualityDiagnosis()
        await content.startAIQualityDiagnosis(token: token, around: nil)

        #expect(await wait { photo.aiDiagnosisFetchedAt != nil })
        #expect(photo.aiExposureBias == -0.5)
        #expect(photo.aiAestheticsOverallScore == nil)
        #expect(photo.aiDiagnosisSchemaVersion == PhotoQualityDiagnosisGenerator.currentSchemaVersion)
    }

    // 診断結果はバックグラウンドのTaskからMainActorへ戻って反映されるため、条件成立をポーリングで待つ
    private func wait(until condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private struct StubQualityImageProvider: AILabelingImageProviding {
    let providesImage: Bool

    func thumbnail(for _: AILabelingTarget) async -> NSImage? {
        providesImage ? NSImage(size: NSSize(width: 1, height: 1)) : nil
    }
}

private struct StubQualityDiagnoser: PhotoQualityDiagnosing {
    let result: PhotoQualityDiagnosis?

    func diagnose(_: NSImage) -> PhotoQualityDiagnosis? {
        result
    }
}
