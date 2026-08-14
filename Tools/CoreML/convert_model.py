"""realesr-general-x4v3 (SRVGGNetCompact) を Core ML .mlpackage へ変換する。

入力: Tools/CoreML/weights/realesr-general-x4v3.pth
出力: Tools/CoreML/build/realesrgan.mlpackage

静的入力形状 [1,3,128,128]、fp16、NCHW、[0,1]レンジ。
実行: /usr/bin/python3 convert_model.py
（torch, coremltoolsは事前に `pip3 install torch coremltools --break-system-packages` 等で導入すること）
"""

import coremltools as ct
import torch

from srvgg_arch import SRVGGNetCompact

WEIGHTS_PATH = "weights/realesr-general-x4v3.pth"
OUTPUT_PATH = "build/realesrgan.mlpackage"
TILE_SIZE = 128
SCALE = 4
NUM_FEAT = 64
NUM_CONV = 32


def load_model() -> SRVGGNetCompact:
    model = SRVGGNetCompact(
        num_in_ch=3, num_out_ch=3, num_feat=NUM_FEAT, num_conv=NUM_CONV,
        upscale=SCALE, act_type="prelu",
    )
    checkpoint = torch.load(WEIGHTS_PATH, map_location="cpu", weights_only=True)
    state_dict = checkpoint.get("params", checkpoint) if isinstance(checkpoint, dict) else checkpoint
    model.load_state_dict(state_dict, strict=True)
    model.eval()
    return model


class ImageIOWrapper(torch.nn.Module):
    """ImageType出力用に [0,1] レンジのモデル出力を [0,255] へスケールしてから返す。
    ImageType入力はscale=1/255で[0,255]→[0,1]へ変換されるため、出力側もCore MLの
    画像出力（値をそのままピクセル値として解釈する）に合わせて255倍で返す必要がある"""

    def __init__(self, inner: torch.nn.Module):
        super().__init__()
        self.inner = inner

    def forward(self, x):
        return torch.clamp(self.inner(x) * 255.0, 0.0, 255.0)


def main() -> None:
    model = ImageIOWrapper(load_model())
    example_input = torch.rand(1, 3, TILE_SIZE, TILE_SIZE)

    with torch.no_grad():
        traced = torch.jit.trace(model, example_input)

    # ImageType入出力にすることで、Swift側はCVPixelBufferを直接渡せる
    # （NCHW/[0,1]レンジへの正規化・出力の非正規化はCore MLランタイム側が行う）。
    # scale=1/255でuint8 [0,255] -> [0,1] fp16へ変換する
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="input", shape=(1, 3, TILE_SIZE, TILE_SIZE),
            scale=1.0 / 255.0, bias=[0.0, 0.0, 0.0],
            color_layout=ct.colorlayout.RGB,
        )],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )

    mlmodel.author = "xinntao (Real-ESRGAN, BSD-3-Clause)"
    mlmodel.short_description = (
        "realesr-general-x4v3 (SRVGGNetCompact), 128x128 -> 512x512, 4x super resolution. "
        "Converted for ShootLog on-device tiled inference."
    )
    mlmodel.version = "1"

    mlmodel.save(OUTPUT_PATH)
    print(f"saved: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
