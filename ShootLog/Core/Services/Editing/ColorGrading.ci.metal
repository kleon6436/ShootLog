//
//  ColorGrading.ci.metal
//  ShootLog
//
//  トーン域別カラーグレーディングの Core Image カーネル。
//  `[[stitchable]]` 属性付きで CoreImage ヘッダとともにコンパイルし、
//  default.metallib として同梱する。CIColorKernel(functionName:fromMetalLibraryData:) でロードする。
//  CIKernel 専用のビルドフラグ（-fcikernel）は不要。
//

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

/// トーン域別カラーグレーディング。入力サンプル（知覚 = ガンマ sRGB 領域）の輝度から
/// shadow / mid / highlight マスクを作り、各域に色オフセットと輝度オフセットを加算する。
/// master は全域一様。すべてのオフセットが 0 のとき入力をそのまま返す。
[[ stitchable ]] float4 colorGrade(
    coreimage::sample_t s,
    float3 masterColor, float masterLight,
    float3 shadowColor, float shadowLight,
    float3 midColor,    float midLight,
    float3 highColor,   float highLight
) {
    float a = s.a;
    float3 rgb = (a > 0.0f) ? s.rgb / a : s.rgb;
    float lum = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
    float wShadow = 1.0f - smoothstep(0.0f, 0.5f, lum);
    float wHigh = smoothstep(0.5f, 1.0f, lum);
    float wMid = max(1.0f - wShadow - wHigh, 0.0f);

    rgb += masterColor + masterLight;
    rgb += wShadow * (shadowColor + shadowLight);
    rgb += wMid * (midColor + midLight);
    rgb += wHigh * (highColor + highLight);
    // 下限のみクランプ。上限は知覚ブラケット後段（HSL LUT / 実体化）に委ねる。
    rgb = max(rgb, 0.0f);
    return float4(rgb * a, a);
}
