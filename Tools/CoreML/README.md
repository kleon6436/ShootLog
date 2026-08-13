# Tools/CoreML

Real-ESRGAN (`realesr-general-x4v3`) の PyTorch 重みを Core ML `.mlpackage` へ変換するための
ツール一式。ライセンス調査結果は `Docs/SuperResolution_モデル選定.md` を参照。

**変換・実測は完了済み。** `ShootLog/Resources/Models/realesrgan.mlpackage`（約2.4MB）が
アプリに同梱されており、`CoreMLSuperResolutionEngine` が実際にこのモデルで推論する。

## 実測結果（2026-08-13、Apple Silicon実機）

| 項目 | 値 |
|---|---|
| 元重み | `realesr-general-x4v3.pth`、4,885,111 bytes、SHA-256 `8dc7edb9...ce96292`（BSD-3-Clause） |
| アーキテクチャ | SRVGGNetCompact、num_feat=64、num_conv=32、upscale=4（重みのshapeから逆算して確定） |
| 変換忠実度（fp32 PyTorch vs fp16 Core ML、生の浮動小数点出力比較） | PSNR 65.2 dB、NaN/Inf検出ゼロ |
| 変換忠実度（ImageType経由・8bit丸め込み後） | PSNR 57.8 dB（8bit量子化誤差が支配的。理論上限に近い値で異常ではない） |
| タイル推論時間（128×128入力、CPU_AND_NE） | 約5〜6.4 ms/タイル |
| タイル推論時間（CPU_AND_GPU） | 約9 ms/タイル |
| タイル推論時間（CPU_ONLY） | 約16.3 ms/タイル |
| 24MP機・4×相当（約1,700タイル、8pxオーバーラップ）の推定総推論時間 | 約8.5秒（ANE） |

Phase0.6の受け入れ基準（タイル推論時間が全computeUnitで2秒を大幅に下回る）を満たしたため、
タイルサイズは初期値の128px・オーバーラップ8pxのまま確定した。

## 手順（再変換する場合）

1. 依存パッケージをインストールする（`torch`, `coremltools`）。このリポジトリでは
   システムのPython 3.9（`/usr/bin/python3`）に `pip3 install torch coremltools --break-system-packages`
   で導入した。Python 3.14系（Homebrew既定）はcoremltoolsが未対応だったため使わないこと。

2. `realesr-general-x4v3.pth` を取得する。

   ```sh
   mkdir -p weights
   curl -sL -o weights/realesr-general-x4v3.pth \
     https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth
   ```

3. 変換を実行する（`srvgg_arch.py` にアーキテクチャ定義を同梱済み。`basicsr` への依存は無い）。

   ```sh
   /usr/bin/python3 convert_model.py
   ```

   `build/realesrgan.mlpackage` が生成される。

4. 生成された `.mlpackage` を `ShootLog/Resources/Models/realesrgan.mlpackage` へ配置し、
   `xcodegen generate` を実行する。`project.yml` の `sources: - path: ShootLog` 設定により
   自動的にXcodeプロジェクトへ取り込まれる（ビルド時に `.mlmodelc` へ自動コンパイルされる）。

## 出力仕様

- 入力: `ImageType`、静的形状 `128×128`、RGB、`scale=1/255` でCore MLランタイムが
  `[0,255]→[0,1]`へ正規化する（Swift側は`CGImage`をそのまま渡せる）
- 出力: `ImageType`、`512×512`、RGB。PyTorchモデルの`[0,1]`出力を255倍してからImageTypeへ
  変換している（`ImageIOWrapper`参照）
- 精度: fp16
- `minimum_deployment_target`: macOS 14

## 数値検証

`convert_model.py` 実行後、以下で忠実度を確認できる（`weights/`が必要）。

```sh
/usr/bin/python3 -c "
import torch, numpy as np, coremltools as ct
from srvgg_arch import SRVGGNetCompact
model = SRVGGNetCompact(num_feat=64, num_conv=32, upscale=4)
ckpt = torch.load('weights/realesr-general-x4v3.pth', map_location='cpu', weights_only=True)
model.load_state_dict(ckpt.get('params', ckpt)); model.eval()
torch.manual_seed(0); x = torch.rand(1,3,128,128)
with torch.no_grad(): ref = model(x).numpy()
mlmodel = ct.models.MLModel('build/realesrgan.mlpackage')
# ImageType入出力のため実際の検証はPIL画像経由で行う（README本文の実測結果を参照）
"
```

`verify_runtime.swift` は、Swift側の実行経路（`MLFeatureValue(cgImage:...)` →
`model.prediction(from:)` → `imageBufferValue`）を`.mlmodelc`に対して直接検証するための
使い捨てスクリプト。ビルド後に以下で実行できる。

```sh
swift Tools/CoreML/verify_runtime.swift \
  "$(find ~/Library/Developer/Xcode/DerivedData -iname 'realesrgan.mlmodelc' -path '*Debug*' | head -1)"
```

## ライセンス注記

`realesr-general-x4v3.pth` はBSD-3-Clause（Copyright (c) 2021, Xintao Wang）。アプリ内クレジット
表示に著作権表示を含めること（文面案は `Docs/SuperResolution_モデル選定.md` の
「NOTICE相当の記載文面案」を参照）。`weights/` `build/` はリポジトリに含めない
（`.gitignore` 参照、公開配布元から再取得可能なため）。
