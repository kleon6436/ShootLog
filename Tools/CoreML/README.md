# Tools/CoreML

Real-ESRGAN (`realesr-general-x4v3`) の PyTorch 重みを Core ML `.mlpackage` へ変換するための
ツール一式。ライセンス調査結果は `Docs/SuperResolution_モデル選定.md` を参照。

現時点では `convert_model.py` は骨格のみで、重みのダウンロードと実際の変換は未実行。
将来のフェーズで以下の手順を実行する。

## 手順（将来実行時）

1. 依存パッケージをインストールする。

   ```sh
   cd Tools/CoreML
   python3 -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   ```

2. `realesr-general-x4v3.pth` を公式リポジトリ（BSD-3-Clause）から取得する。

   https://github.com/xinntao/Real-ESRGAN/releases

3. SRVGGNetCompact構造の読み込みに `basicsr`（または同等の最小実装）が必要。
   `convert_model.py` の `load_pytorch_model` のdocstringにコード例を記載している。

4. 変換を実行する。

   ```sh
   python convert_model.py --weights /path/to/realesr-general-x4v3.pth \
       --output realesr_general_x4v3_fp16_static128.mlpackage
   ```

5. 生成された `.mlpackage` を `ShootLog/Resources/Models/` 配下に配置する。
   `project.yml` の `sources: - path: ShootLog` 設定により、XcodeGen再生成時に
   自動的にXcodeプロジェクトへ取り込まれる（`project.yml`自体の編集は別タスクが担当）。

## 出力仕様

- 入力: 静的形状 `[1, 3, 128, 128]`、NCHW、値レンジ `[0, 1]`
- 精度: fp16
- `compute_units`: ANE/GPU/CPUをすべて許可（`ct.ComputeUnit.ALL`）し、実行時にOSへ選択を委ねる

## ライセンス注記

`realesr-general-x4v3.pth` はBSD-3-Clause（Copyright (c) 2021, Xintao Wang）。変換後の
`.mlpackage` をアプリに同梱する場合は、アプリ内クレジット表示に著作権表示を含めること
（文面案は `Docs/SuperResolution_モデル選定.md` の「NOTICE相当の記載文面案」を参照）。
