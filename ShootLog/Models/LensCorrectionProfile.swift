import Foundation
import SwiftData

/// カメラ・レンズ・焦点距離に応じた手動レンズ補正値。
///
/// 特定の写真には紐付かず、複数の写真で共有するグローバルなプロファイルとして保持する。
@Model
final class LensCorrectionProfile {
    /// 安定した識別子。
    var id: UUID = UUID()
    /// EXIF から取得したカメラ機種名。
    var cameraModel: String = ""
    /// EXIF から取得したレンズ名。
    var lensModel: String = ""
    /// 焦点距離（mm）。`0` は焦点距離を問わないプロファイルを表す。
    var focalLength: Double = 0
    /// 歪曲補正量（-100...100）。`LensCorrectionFilter.corrected(_:distortion:vignette:chromaticAberration:)` の `distortion` に対応する。
    var distortionAmount: Double = 0
    /// 周辺光量補正量（-100...100）。`LensCorrectionFilter.corrected(_:distortion:vignette:chromaticAberration:)` の `vignette` に対応する。
    var vignetteAmount: Double = 0
    /// 色収差補正量（-100...100）。`LensCorrectionFilter.corrected(_:distortion:vignette:chromaticAberration:)` の `chromaticAberration` に対応する。
    var chromaticAberrationAmount: Double = 0
    /// プロファイルの作成日時。
    var createdAt: Date = Date.now

    init(
        id: UUID = UUID(),
        cameraModel: String = "",
        lensModel: String = "",
        focalLength: Double = 0,
        distortionAmount: Double = 0,
        vignetteAmount: Double = 0,
        chromaticAberrationAmount: Double = 0,
        createdAt: Date = Date.now
    ) {
        self.id = id
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.distortionAmount = distortionAmount
        self.vignetteAmount = vignetteAmount
        self.chromaticAberrationAmount = chromaticAberrationAmount
        self.createdAt = createdAt
    }
}
