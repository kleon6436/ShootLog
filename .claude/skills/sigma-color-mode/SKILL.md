---
name: sigma-color-mode
description: Sigma fp L の PictureMode（カラーモード）を EXIF/DNG から読み取り・表示する際の実装知識。EXIFService や EXIF パネルのカラーモード関連コードを触るときに使う。
---

# Sigma fp L カラーモード対応

## 実測済みの事実（FPL00857.DNG）

- `MakerNote.PictureMode` タグに文字列で記録される（例: `"PowderBlue"`）
- DNG標準タグ（`ProfileHueSatMapData1/2`・`ProfileToneCurve`）に色変換データが埋め込まれる

## 実装方針

**Step 1**：`CGImageSourceCreateImageAtIndex` でそのまま読み込む。ImageIO が埋め込みプロファイルを自動適用するため、追加実装なしで再現できる可能性が高い。

**Step 2**（Step 1で色が出ない場合）：`ProfileHueSatMapData` を手動パースして Core Image フィルタに変換する。詳細は規約書セクション13を参照。

## EXIFパネル表示

```swift
// カラーモードが "Off" または nil の場合は表示しない
if let mode = photo.colorMode, mode != "Off" {
    EXIFRowView(key: "カラーモード", value: mode, style: .badge)
}
```

## 対応カラーモード文字列（PictureMode タグ値）

`Standard` / `Vivid` / `Neutral` / `Portrait` / `Landscape` / `Cinema` /
`WarmGold` / `TealAndOrange` / `SunsetRed` / `ForestGreen` / `PowderBlue` /
`FOVClassicBlue` / `FOVClassicYellow` / `Duotone` / `Monochrome` / `Off`
