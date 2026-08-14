# Tools/CoreML

Real-ESRGAN の PyTorch 重みを Core ML `.mlpackage` へ変換するためのツール一式。
ライセンス調査結果は `Docs/SuperResolution_モデル選定.md` を参照。

対象モデルは2種類ある。

| 倍率 | 重み | アーキテクチャ | 変換スクリプト | 出力 |
|---|---|---|---|---|
| 4倍 | `realesr-general-x4v3.pth` | `SRVGGNetCompact`（`srvgg_arch.py`） | `convert_model.py` | `build/realesrgan.mlpackage` |
| 2倍 | `RealESRGAN_x2plus.pth` | `RRDBNet`（`rrdbnet_arch.py`） | `convert_model_x2plus.py` | `build/realesrgan_x2plus.mlpackage` |

**4倍モデルの変換・実測は完了済み。** `ShootLog/Resources/Models/realesrgan.mlpackage`（約2.4MB）が
アプリに同梱されており、`CoreMLSuperResolutionEngine` が実際にこのモデルで推論する。

## 4倍モデルの実測結果（2026-08-13、Apple Silicon実機）

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

## 2倍モデルの実測結果（2026-08-14、Apple M2 Pro / macOS 26.6.1）

**判定: 採用。** Phase0.6の受け入れ基準（タイル推論時間が全computeUnitで2秒を大幅に下回る）を
大きく満たし、継ぎ目アーティファクトも検出されなかった。

| 項目 | 値 |
|---|---|
| 元重み | `RealESRGAN_x2plus.pth`、67,061,725 bytes、SHA-256 `49fafd45...fa266abb` |
| 重みのライセンス | BSD-3-Clause（Copyright (c) 2021, Xintao Wang） |
| アーキテクチャ | RRDBNet、num_feat=64、num_block=23、num_grow_ch=32、scale=2、16,703,171パラメータ |
| アーキテクチャのライセンス | Apache-2.0（Copyright 2018-2022 BasicSR Authors。重みとは別ライセンス） |
| 重みのstate_dictキー | `params_ema`（4倍モデルの `params` とは異なる点に注意） |
| 変換忠実度（fp32 PyTorch vs fp16 Core ML、生の浮動小数点出力比較） | PSNR 71.1 dB、NaN/Inf検出ゼロ |
| 変換忠実度（ImageType経由・8bit丸め込み後） | PSNR 47.3 dB（平均絶対誤差 0.67／255階調、中央値 0.41） |
| `.mlpackage` サイズ | 約33MB（4倍モデルの約2.4MBに対し約14倍） |

### タイル推論時間（128×128入力 → 256×256出力、ウォームアップ3回後20回の統計）

| computeUnit | 中央値 | 平均 | 最大 |
|---|---|---|---|
| `cpuAndNeuralEngine` | 10.39 ms | 10.39 ms | 10.48 ms |
| `cpuAndGPU` | 30.34 ms | 30.82 ms | 33.86 ms |
| `cpuOnly` | 56.17 ms | 56.33 ms | 58.20 ms |

24MP機（6000×4000、`inputStride` 120 で 50×34 = 1,700タイル）の推定総推論時間は
ANEで約17.7秒、GPUで約52秒、CPU専用で約96秒。

**注意: 2倍モデルは4倍モデルより出力が小さいにもかかわらず処理時間は約2倍かかる**
（同一原寸画像でANE 約17.7秒 vs 約8.5秒）。タイル分割は入力側で行うためタイル枚数が
両モデルで同一（1,700枚）であり、1タイルあたりの計算量だけがRRDBNetの方が大きいため。
「2倍の方が軽い」という直感に反するので、UI上の期待値設定には注意すること。

### 継ぎ目アーティファクト評価

タイル分割＋フェザーブレンド後の出力を、画像全体を一括推論したPyTorch fp32出力と比較した
（`TiledInferenceRunner` の `placements` / `featherWeights` と同じ計算をnumpyで再現）。

| inputOverlap | inputStride | PSNR（タイル vs 一括） | タイル別平均誤差の標準偏差 | 継ぎ目の水平段差 vs 全体平均 |
|---|---|---|---|---|
| 8 | 120 | 29.14 dB | 0.804 | 3.175 vs 3.597 |
| 16 | 112 | 27.50 dB | 0.922 | 4.269 vs 4.355 |
| 32 | 96 | 26.74 dB | 1.043 | 4.316 vs 4.644 |
| 48 | 80 | 28.06 dB | 1.156 | 4.942 vs 3.936 |

読み取り方:

- **継ぎ目の段差は検出されない。** 継ぎ目位置の水平1次差分が画像全体の平均を下回っており
  （overlap 8で3.175 vs 3.597）、フェザーブレンドが不連続を作っていないことを示す。
  タイル別の平均誤差の標準偏差も1階調未満で、タイル格子状のブロックノイズも生じていない。
- **`inputOverlap` を増やしても改善しない。** これはタイル境界の問題ではなく、RRDBNet（23 RRDBブロック）の
  受容野が128pxタイルより大きく、タイル全体が一括推論時の文脈を持てないことに起因するため。
  Real-ESRGAN公式実装も同様にタイル分割を前提としており、この差分は「品質劣化」ではなく
  「一括推論との出力差」である。したがって**オーバーラップは既定の8pxのまま採用する**（最も
  PSNRが高くブロックノイズも小さい）。
- 参考として、同一手法で4倍モデルを測ると57.21 dBとなる。2倍モデルの値が低いのは上記の受容野差によるもので、
  4倍モデル側の受容野（33畳み込み層相当）が128pxタイルに収まっていることの裏返しである。

`ImageType` 経由の忠実度が4倍モデル（PSNR 57.8 dB、平均絶対誤差 0.26）より低いのは、
GANベースのRRDBNet出力が高コントラストな急峻エッジを多く含み、fp16の丸めが8bit量子化段で
別の階調に落ちる画素が生じるため。誤差の大半は1階調未満（中央値0.41）で、
10階調を超える画素は全体の0.04%（196,608画素中75画素）に留まり、視認できる差ではない。

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

### 2倍モデルの場合

手順1・4は共通。重み取得と変換だけが異なる。

```sh
mkdir -p weights
curl -sL -o weights/RealESRGAN_x2plus.pth \
  https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth
/usr/bin/python3 convert_model_x2plus.py
```

`build/realesrgan_x2plus.mlpackage` が生成される（`rrdbnet_arch.py` にアーキテクチャ定義を
同梱済みで、`basicsr` への依存は無い）。配置先は `ShootLog/Resources/Models/realesrgan_x2plus.mlpackage`。

## 出力仕様

両モデル共通で、入力は `ImageType`、静的形状 `128×128`、RGB、`scale=1/255` でCore MLランタイムが
`[0,255]→[0,1]`へ正規化する（Swift側は`CGImage`をそのまま渡せる）。
出力も `ImageType` / RGB で、PyTorchモデルの`[0,1]`出力を255倍してからImageTypeへ変換している
（`ImageIOWrapper`参照）。精度はfp16、`minimum_deployment_target` は macOS 14。

| モデル | 入力 | 出力 |
|---|---|---|
| 4倍（`realesrgan.mlpackage`） | 128×128 | 512×512 |
| 2倍（`realesrgan_x2plus.mlpackage`） | 128×128 | 256×256 |

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

2倍モデルのタイル推論時間を全computeUnitで計測する場合は、`xcrun coremlcompiler` で
`.mlmodelc` へコンパイルしてから同じ経路で実行する。

```sh
xcrun coremlcompiler compile build/realesrgan_x2plus.mlpackage build/
```

## ライセンス注記

重みとアーキテクチャ実装でライセンスが異なるため、アプリ内クレジット表示には両方を含めること
（文面案は `Docs/SuperResolution_モデル選定.md` の「NOTICE相当の記載文面案」を参照）。

| 対象 | ライセンス | 著作権表示 |
|---|---|---|
| `realesr-general-x4v3.pth` / `RealESRGAN_x2plus.pth`（重み） | BSD-3-Clause | Copyright (c) 2021, Xintao Wang |
| `srvgg_arch.py`（Real-ESRGANから移植） | BSD-3-Clause | Copyright (c) 2021, Xintao Wang |
| `rrdbnet_arch.py`（BasicSRから移植） | Apache-2.0 | Copyright 2018-2022 BasicSR Authors |

`weights/` `build/` はリポジトリに含めない（`.gitignore` 参照、公開配布元から再取得可能なため）。
