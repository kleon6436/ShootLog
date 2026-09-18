import Testing

@testable import ShootLog

struct RAWDevelopMappingTests {

    @Test func decodeHashChangesOnlyForDelegatedParameters() {
        let base = DevelopParameters.neutral
        let baseHash = RAWDevelopMapping.decodeHash(base)

        let sameHash = DevelopParameters.neutral
        #expect(RAWDevelopMapping.decodeHash(sameHash) == baseHash)

        var exposureChanged = DevelopParameters.neutral
        exposureChanged.exposure = 0.5
        #expect(RAWDevelopMapping.decodeHash(exposureChanged) != baseHash)

        var wbChanged = DevelopParameters.neutral
        wbChanged.temperature = 20
        #expect(RAWDevelopMapping.decodeHash(wbChanged) != baseHash)

        var absoluteWBChanged = DevelopParameters.neutral
        absoluteWBChanged.whiteBalance = .preset(.tungsten)
        #expect(RAWDevelopMapping.decodeHash(absoluteWBChanged) != baseHash)

        var lensChanged = DevelopParameters.neutral
        lensChanged.lensCorrectionEnabled = true
        #expect(RAWDevelopMapping.decodeHash(lensChanged) != baseHash)

        // 非委譲パラメータではハッシュは変わらない。
        var contrastChanged = DevelopParameters.neutral
        contrastChanged.contrast = 60
        contrastChanged.sharpness = 30
        contrastChanged.luminanceNoiseReduction = 40
        #expect(RAWDevelopMapping.decodeHash(contrastChanged) == baseHash)
    }

}
