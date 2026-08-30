//
//  LensDistortion.ci.metal
//  ShootLog
//
//  手動レンズ歪曲補正の Core Image ワープカーネル。
//  `[[stitchable]]` 属性付きで CoreImage ヘッダとともにコンパイルし、
//  default.metallib として同梱する。CIWarpKernel(functionName:fromMetalLibraryData:) でロードする。
//
//  v3 Phase 5-1 ではビルド疎通の確認のため恒等ワープのみ。
//  多項式歪曲補正の逆写像は Phase 5-2 で実装する。
//

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

/// レンズ歪曲補正のワープカーネル。
///
/// 出力座標 `dest.coord()` に対して、サンプリングすべき入力座標を返す。
/// Phase 5-1 では恒等（入力座標 = 出力座標）。
[[ stitchable ]] float2 lensDistortionWarp(coreimage::destination dest) {
    return dest.coord();
}
