import SwiftUI

// FullscreenModeView の補助 View。FullscreenModeView.swift から参照するため internal

struct NavButton: View {
    enum Direction { case prev, next }
    let direction: Direction
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .prev ? "chevron.left" : "chevron.right")
                .foregroundStyle(Color.onViewerCanvas)
                .frame(width: 44, height: 44)
                .glassOrMaterialCircle()
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.control))
        .accessibilityLabel(direction == .prev ? "viewer.previousPhoto" : "viewer.nextPhoto")
    }
}

// 右上グラスクラスタ内のアイコンボタン。背景はクラスタ全体（capsule）が担うため、
// 個々のボタンは円形グラスを持たない（NavButton等とは異なる）
struct HUDClusterButton: View {
    let systemImage: String
    var tint: Color = Color.onViewerCanvasSecondary
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 40, height: 36)
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
        .accessibilityLabel(accessibilityLabel)
    }
}

// 下部左のEXIFキャプション表示内容
struct EXIFCaptionContent {
    let fileName: String
    // "f/8 · 1/250 s · ISO 100 · 35 mm" 形式（欠損する項目は自動的に省かれる）
    let summary: String
    let cameraModel: String?
}

extension EXIFCaptionContent {
    // EXIF未取得の写真（または写真未選択）ではnilを返し、キャプションを表示しない
    @MainActor
    init?(photo: Photo?) {
        guard let photo, photo.exifFetchedAt != nil else { return nil }
        let panelVM = EXIFPanelViewModel(photo: photo)

        // アパーチャ・ISOはEXIFパネルの表示（ラベル併記前提の書式）と異なり、
        // ラベル無しの短い書式（f/8, ISO 100）が必要なためここで組み立てる。
        // シャッタースピード・焦点距離はEXIFパネルと同じ書式で問題ないため流用する
        var segments: [String] = []
        if let aperture = photo.aperture {
            segments.append("f/" + aperture.formatted(.number.precision(.fractionLength(1)).grouping(.never)))
        }
        if let shutterSpeedText = panelVM.shutterSpeedText {
            segments.append(shutterSpeedText)
        }
        if let iso = photo.iso {
            segments.append("ISO \(iso)")
        }
        if let focalLengthText = panelVM.focalLengthText {
            segments.append(focalLengthText)
        }

        self.init(
            fileName: panelVM.fileNameText ?? "",
            summary: segments.joined(separator: " · "),
            cameraModel: panelVM.cameraModelText
        )
    }
}

struct EXIFCaptionCapsule: View {
    let content: EXIFCaptionContent

    var body: some View {
        HStack(spacing: 8) {
            Text(content.fileName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            if !content.summary.isEmpty {
                CaptionSeparator()
                Text(content.summary)
                    .font(.caption)
                    .monospacedDigit()
            }

            if let cameraModel = content.cameraModel, !cameraModel.isEmpty {
                CaptionSeparator()
                Text(cameraModel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .glassOrMaterialCapsule()
        .accessibilityElement(children: .combine)
    }
}

struct CaptionSeparator: View {
    var body: some View {
        Divider()
            .frame(width: 1, height: 12)
    }
}
