"""RealESRGAN_x2plus (RRDBNet) を Core ML .mlpackage へ変換する。

入力: Tools/CoreML/weights/RealESRGAN_x2plus.pth
出力: Tools/CoreML/build/realesrgan_x2plus.mlpackage

静的入力形状 [1,3,128,128]、fp16、NCHW、[0,1]レンジ。出力は 256x256（2倍）。
実行: /usr/bin/python3 convert_model_x2plus.py
（torch, coremltoolsは事前に `pip3 install torch coremltools --break-system-packages` 等で導入すること）
"""

import coremltools as ct
import torch

from rrdbnet_arch import RRDBNet

WEIGHTS_PATH = "weights/RealESRGAN_x2plus.pth"
OUTPUT_PATH = "build/realesrgan_x2plus.mlpackage"
TILE_SIZE = 128
SCALE = 2
NUM_FEAT = 64
NUM_BLOCK = 23
NUM_GROW_CH = 32


def load_model() -> RRDBNet:
    model = RRDBNet(
        num_in_ch=3, num_out_ch=3, num_feat=NUM_FEAT, num_block=NUM_BLOCK,
        num_grow_ch=NUM_GROW_CH, scale=SCALE,
    )
    checkpoint = torch.load(WEIGHTS_PATH, map_location="cpu", weights_only=True)
    # 4倍モデル(realesr-general-x4v3)は "params" だが、x2plusの配布重みは "params_ema" に入っている
    if isinstance(checkpoint, dict):
        state_dict = checkpoint.get("params_ema", checkpoint.get("params", checkpoint))
    else:
        state_dict = checkpoint
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

    mlmodel.author = "xinntao (Real-ESRGAN, BSD-3-Clause) / BasicSR Authors (RRDBNet, Apache-2.0)"
    mlmodel.short_description = (
        f"RealESRGAN_x2plus (RRDBNet), {TILE_SIZE}x{TILE_SIZE} -> "
        f"{TILE_SIZE * SCALE}x{TILE_SIZE * SCALE}, 2x super resolution. "
        "Converted for ShootLog on-device tiled inference."
    )
    mlmodel.version = "1"

    mlmodel.save(OUTPUT_PATH)
    print(f"saved: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
