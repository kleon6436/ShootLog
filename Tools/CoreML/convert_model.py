"""Real-ESRGAN (realesr-general-x4v3 / SRVGGNetCompact) の PyTorch 重みを
Core ML .mlpackage へ変換するスクリプトの骨格。

ライセンス調査結果は Docs/SuperResolution_モデル選定.md を参照。
このスクリプトは骨格のみであり、重みのダウンロードと実際の変換は
別フェーズで実行する（今回は実行しない）。

想定する変換条件:
- 入力形状: 静的 [1, 3, 128, 128]（NCHW）
- 精度: fp16
- 入力レンジ: [0, 1]（ImageIOで正規化してから渡す想定）
"""

from __future__ import annotations

import argparse
from pathlib import Path


def load_pytorch_model(weights_path: Path):
    """realesr-general-x4v3.pth を読み込み、SRVGGNetCompact構造で復元する。

    実行時のイメージ（要 basicsr / realesrgan パッケージ、または
    SRVGGNetCompact 単体実装の同梱）:

        import torch
        from basicsr.archs.srvgg_arch import SRVGGNetCompact

        model = SRVGGNetCompact(
            num_in_ch=3, num_out_ch=3, num_feat=64,
            num_conv=32, upscale=4, act_type="prelu",
        )
        state_dict = torch.load(weights_path, map_location="cpu", weights_only=True)
        model.load_state_dict(state_dict["params"], strict=True)
        model.eval()
        return model
    """
    raise NotImplementedError("Phase0.5では未実行。別フェーズで実装する。")


def trace_model(model, input_shape: tuple[int, int, int, int]):
    """torch.jit.trace でグラフを固定する。

    実行時のイメージ:

        import torch

        example_input = torch.rand(*input_shape)
        traced = torch.jit.trace(model, example_input)
        return traced
    """
    raise NotImplementedError("Phase0.5では未実行。別フェーズで実装する。")


def convert_to_coreml(traced_model, input_shape: tuple[int, int, int, int], output_path: Path):
    """coremltools で .mlpackage へ変換する。

    実行時のイメージ:

        import coremltools as ct

        mlmodel = ct.convert(
            traced_model,
            inputs=[
                ct.TensorType(
                    name="input_image",
                    shape=input_shape,          # 静的 [1, 3, 128, 128]
                    dtype=ct.converters.mil.mil.types.fp16,
                )
            ],
            outputs=[ct.TensorType(name="output_image")],
            compute_precision=ct.precision.FLOAT16,
            compute_units=ct.ComputeUnit.ALL,   # ANE/GPU/CPUを許可
            minimum_deployment_target=ct.target.macOS14,
            convert_to="mlprogram",
        )
        mlmodel.save(str(output_path))
        return mlmodel
    """
    raise NotImplementedError("Phase0.5では未実行。別フェーズで実装する。")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--weights",
        type=Path,
        required=True,
        help="realesr-general-x4v3.pth へのパス（BSD-3-Clause, xinntao/Real-ESRGAN由来）",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("realesr_general_x4v3_fp16_static128.mlpackage"),
        help="出力先の .mlpackage パス",
    )
    parser.add_argument(
        "--input-size",
        type=int,
        default=128,
        help="静的入力の一辺サイズ（デフォルト128、Real-ESRGAN-CoreAI変換版に合わせる）",
    )
    args = parser.parse_args()

    input_shape = (1, 3, args.input_size, args.input_size)

    model = load_pytorch_model(args.weights)
    traced = trace_model(model, input_shape)
    convert_to_coreml(traced, input_shape, args.output)


if __name__ == "__main__":
    main()
