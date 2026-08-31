import Testing

@testable import ShootLog

/// レンズ補正プロファイルの検索・補間ロジックのテスト。
struct LensProfileStoreTests {

    @Test func returnsAmountsForExactFocalLengthMatch() {
        let profile = makeProfile(focalLength: 35, distortion: 12, vignette: -8, chromaticAberration: 4)

        let match = LensProfileStore.bestMatch(
            in: [profile], cameraModel: "Camera", lensModel: "Lens", focalLength: 35
        )

        #expect(match == LensCorrectionAmounts(distortion: 12, vignette: -8, chromaticAberration: 4))
    }

    @Test func interpolatesAmountsBetweenFocalLengthProfiles() throws {
        let profiles = [
            makeProfile(focalLength: 24, distortion: 10, vignette: -20, chromaticAberration: 4),
            makeProfile(focalLength: 70, distortion: 30, vignette: 20, chromaticAberration: 14)
        ]

        let match = LensProfileStore.bestMatch(
            in: profiles, cameraModel: "Camera", lensModel: "Lens", focalLength: 47
        )

        let amounts = try #require(match)
        #expect(abs(amounts.distortion - 20) < 1e-9)
        #expect(abs(amounts.vignette) < 1e-9)
        #expect(abs(amounts.chromaticAberration - 9) < 1e-9)
    }

    @Test func returnsNilWhenCameraModelDoesNotMatch() {
        let match = LensProfileStore.bestMatch(
            in: [makeProfile()], cameraModel: "Other Camera", lensModel: "Lens", focalLength: 35
        )

        #expect(match == nil)
    }

    @Test func returnsNilWhenLensModelDoesNotMatch() {
        let match = LensProfileStore.bestMatch(
            in: [makeProfile()], cameraModel: "Camera", lensModel: "Other Lens", focalLength: 35
        )

        #expect(match == nil)
    }

    @Test func clampsToNearestFocalLengthOutsideProfileRange() {
        let profiles = [
            makeProfile(focalLength: 24, distortion: 10, vignette: -20, chromaticAberration: 4),
            makeProfile(focalLength: 70, distortion: 30, vignette: 20, chromaticAberration: 14)
        ]

        let match = LensProfileStore.bestMatch(
            in: profiles, cameraModel: "Camera", lensModel: "Lens", focalLength: 100
        )

        #expect(match == LensCorrectionAmounts(distortion: 30, vignette: 20, chromaticAberration: 14))
    }

    @Test func matchesCameraAndLensIgnoringWhitespaceAndCase() {
        let match = LensProfileStore.bestMatch(
            in: [makeProfile(cameraModel: "  CAMERA  ", lensModel: "  LENS  ")],
            cameraModel: "camera", lensModel: "lens", focalLength: 35
        )

        #expect(match != nil)
    }

    @Test func returnsFocalLengthIndependentProfileWhenNoSpecificProfilesExist() {
        let profile = makeProfile(focalLength: 0, distortion: 12, vignette: -8, chromaticAberration: 4)

        let match = LensProfileStore.bestMatch(
            in: [profile], cameraModel: "Camera", lensModel: "Lens", focalLength: 85
        )

        #expect(match == LensCorrectionAmounts(distortion: 12, vignette: -8, chromaticAberration: 4))
    }

    private func makeProfile(
        cameraModel: String = "Camera",
        lensModel: String = "Lens",
        focalLength: Double = 35,
        distortion: Double = 0,
        vignette: Double = 0,
        chromaticAberration: Double = 0
    ) -> LensCorrectionProfile {
        LensCorrectionProfile(
            cameraModel: cameraModel,
            lensModel: lensModel,
            focalLength: focalLength,
            distortionAmount: distortion,
            vignetteAmount: vignette,
            chromaticAberrationAmount: chromaticAberration
        )
    }
}
