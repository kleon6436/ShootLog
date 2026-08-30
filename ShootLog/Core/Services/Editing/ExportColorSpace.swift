import CoreGraphics
import Foundation

/// 現像書き出しの出力カラースペース。プレビューは常に sRGB のままで、この選択は書き出しにのみ効く。
enum ExportColorSpace: String, CaseIterable, Identifiable, Sendable {
    case sRGB
    case displayP3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sRGB: String(localized: "develop.export.colorSpace.srgb")
        case .displayP3: String(localized: "develop.export.colorSpace.displayP3")
        }
    }

    /// エンコードへ渡す `CGColorSpace`。生成に失敗した場合は sRGB へフォールバックする。
    var cgColorSpace: CGColorSpace {
        let fallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        switch self {
        case .sRGB:
            return fallback
        case .displayP3:
            return CGColorSpace(name: CGColorSpace.displayP3) ?? fallback
        }
    }
}
