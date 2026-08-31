//
//  LensDistortion.ci.metal
//  ShootLog
//
//  手動レンズ歪曲補正の Core Image ワープカーネル。
//  `[[stitchable]]` 属性付きで CoreImage ヘッダとともにコンパイルし、
//  default.metallib として同梱する。CIWarpKernel(functionName:fromMetalLibraryData:) でロードする。
//  CIKernel 専用のビルドフラグ（-fcikernel）は不要。
//

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

/// レンズ歪曲補正のワープカーネル（放射方向の多項式モデル）。
///
/// 出力座標 `dest.coord()` に対して、サンプリングすべき入力座標を返す。
/// 中心からの画素オフセット `d` を正規化半径 `r` で `1 + k1 r^2 + k2 r^4` 倍する。
/// `k1 == k2 == 0` のとき恒等（入力座標 = 出力座標）。
///
/// - Parameters:
///   - center: 画像中心の画素座標。
///   - normScale: 画素オフセットを正規化半径へ変換する係数（長辺の半分で概ね 1）。
///   - k1: 2 次の歪曲係数。正で樽型を補正（外側ほど大きくサンプル）。
///   - k2: 4 次の歪曲係数。
[[ stitchable ]] float2 lensDistortionWarp(
    float2 center,
    float normScale,
    float k1,
    float k2,
    coreimage::destination dest
) {
    float2 d = dest.coord() - center;
    float2 dn = d * normScale;
    float r2 = dot(dn, dn);
    float factor = 1.0f + k1 * r2 + k2 * r2 * r2;
    return center + d * factor;
}
