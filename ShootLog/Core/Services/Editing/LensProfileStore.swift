import Foundation

/// レンズ補正の 3 補正量。`LensCorrectionFilter.corrected` の引数と対応する。
struct LensCorrectionAmounts: Equatable, Sendable {
    var distortion: Double
    var vignette: Double
    var chromaticAberration: Double
}

/// 保存済みレンズ補正プロファイルから、EXIF 情報に最も適した補正量を選ぶ。
enum LensProfileStore {
    /// 焦点距離の一致とみなす許容誤差。
    private static let focalLengthTolerance = 1e-3

    /// カメラ機種・レンズ・焦点距離に最も合うプロファイルの補正量を返す。該当なしは `nil`。
    ///
    /// 機種とレンズで一致したものだけを対象にする。焦点距離付きプロファイルは完全一致を優先し、
    /// 範囲内では隣接点を線形補間、範囲外では端点へクランプする。焦点距離付きプロファイルが無い場合だけ、
    /// 焦点距離非依存（`focalLength == 0`）のプロファイルへフォールバックする。
    static func bestMatch(
        in profiles: [LensCorrectionProfile],
        cameraModel: String,
        lensModel: String,
        focalLength: Double
    ) -> LensCorrectionAmounts? {
        let matchingProfiles = profiles.filter {
            matches($0.cameraModel, cameraModel) && matches($0.lensModel, lensModel)
        }
        guard !matchingProfiles.isEmpty else { return nil }

        let focalLengthProfiles = matchingProfiles
            .filter { $0.focalLength > 0 }
            .sorted { $0.focalLength < $1.focalLength }

        if let exactMatch = focalLengthProfiles.first(where: {
            abs($0.focalLength - focalLength) <= focalLengthTolerance
        }) {
            return amounts(for: exactMatch)
        }

        if let first = focalLengthProfiles.first, let last = focalLengthProfiles.last {
            if focalLength < first.focalLength {
                return amounts(for: first)
            }
            if focalLength > last.focalLength {
                return amounts(for: last)
            }

            if let upperIndex = focalLengthProfiles.firstIndex(where: { $0.focalLength > focalLength }) {
                let lower = focalLengthProfiles[upperIndex - 1]
                let upper = focalLengthProfiles[upperIndex]
                return interpolatedAmounts(from: lower, to: upper, at: focalLength)
            }
        }

        if let focalLengthIndependentProfile = matchingProfiles.first(where: { $0.focalLength == 0 }) {
            return amounts(for: focalLengthIndependentProfile)
        }

        return nil
    }

    /// EXIF 文字列の表記ゆれを吸収して比較する。
    private static func matches(_ storedValue: String, _ requestedValue: String) -> Bool {
        storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(requestedValue.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// プロファイルの保存値をフィルタ入力用の値へ変換する。
    private static func amounts(for profile: LensCorrectionProfile) -> LensCorrectionAmounts {
        LensCorrectionAmounts(
            distortion: profile.distortionAmount,
            vignette: profile.vignetteAmount,
            chromaticAberration: profile.chromaticAberrationAmount
        )
    }

    /// 隣接する焦点距離プロファイルの補正量を線形補間する。
    private static func interpolatedAmounts(
        from lower: LensCorrectionProfile,
        to upper: LensCorrectionProfile,
        at focalLength: Double
    ) -> LensCorrectionAmounts {
        let ratio = (focalLength - lower.focalLength) / (upper.focalLength - lower.focalLength)
        return LensCorrectionAmounts(
            distortion: lower.distortionAmount + (upper.distortionAmount - lower.distortionAmount) * ratio,
            vignette: lower.vignetteAmount + (upper.vignetteAmount - lower.vignetteAmount) * ratio,
            chromaticAberration: lower.chromaticAberrationAmount
                + (upper.chromaticAberrationAmount - lower.chromaticAberrationAmount) * ratio
        )
    }
}
