import Foundation

/// HSL の色立方体（32³ の `CIColorCube` データ ≒ 512KB）を毎レンダー作り直さないための
/// 直近 1 件メモ。スライダー操作中は露出などが動く一方 HSL は据え置きになることが多く、
/// その間の cube 再生成を丸ごと省ける。
///
/// `NSLock` で保護し、返すのは値型の `Data`（コピー）なので、複数レンダーが並行しても安全。
/// そのため `@unchecked Sendable` を名乗ってよい。
final class DevelopPipelineCache: @unchecked Sendable {
    private struct Key: Equatable {
        let hue: [Double]
        let saturation: [Double]
        let luminance: [Double]
    }

    private let lock = NSLock()
    private var key: Key?
    private var cubeData: Data?

    /// HSL パラメータに対応する cube データ。中立なら `nil`。同一パラメータの連続要求は再計算しない。
    func hslCubeData(hue: [Double], saturation: [Double], luminance: [Double]) -> Data? {
        let requested = Key(hue: hue, saturation: saturation, luminance: luminance)
        lock.lock()
        defer { lock.unlock() }
        if key == requested { return cubeData }

        let computed = HSLColorCube.isNeutral(hue: hue, saturation: saturation, luminance: luminance)
            ? nil
            : HSLColorCube.cubeData(hue: hue, saturation: saturation, luminance: luminance)
        key = requested
        cubeData = computed
        return computed
    }
}
