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

    @Test func hasEffectReflectsDelegatedParametersOnly() {
        #expect(RAWDevelopMapping.hasEffect(.neutral) == false)

        var exposure = DevelopParameters.neutral
        exposure.exposure = 1.0
        #expect(RAWDevelopMapping.hasEffect(exposure))

        var tint = DevelopParameters.neutral
        tint.tint = -15
        #expect(RAWDevelopMapping.hasEffect(tint))

        var lens = DevelopParameters.neutral
        lens.lensCorrectionEnabled = true
        #expect(RAWDevelopMapping.hasEffect(lens))

        var nonDelegated = DevelopParameters.neutral
        nonDelegated.shadows = 50
        nonDelegated.colorNoiseReduction = 30
        #expect(RAWDevelopMapping.hasEffect(nonDelegated) == false)
    }
}
