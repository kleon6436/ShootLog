import SwiftData
import Testing

@testable import ShootLog

/// レンズ補正プロファイルの SwiftData 永続化テスト。
struct LensCorrectionProfileTests {

    @Test func insertsAndFetchesProfile() throws {
        let container = try ModelContainer(
            for: LensCorrectionProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let profile = LensCorrectionProfile(
            cameraModel: "SIGMA fp L",
            lensModel: "45mm F2.8 DG DN",
            focalLength: 45,
            distortionAmount: 8,
            vignetteAmount: -6,
            chromaticAberrationAmount: 3
        )
        context.insert(profile)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<LensCorrectionProfile>())

        #expect(fetched.count == 1)
        #expect(fetched.first?.cameraModel == "SIGMA fp L")
        #expect(fetched.first?.distortionAmount == 8)
    }
}
