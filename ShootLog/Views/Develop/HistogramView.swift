import SwiftUI

/// RGB ヒストグラム。各チャンネルを加算合成で重ねて描く。
/// データが無い間はプレースホルダの枠だけ出す。
struct HistogramView: View {
    let data: HistogramData?

    private let height: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.small)
                .fill(.quaternary.opacity(0.4))

            if let data {
                Canvas { context, size in
                    draw(channel: data.red, color: .red, in: &context, size: size)
                    draw(channel: data.green, color: .green, in: &context, size: size)
                    draw(channel: data.blue, color: .blue, in: &context, size: size)
                }
                .blendMode(.plusLighter)
                .padding(2)
            }
        }
        .frame(height: height)
        .accessibilityLabel("develop.histogram")
        .accessibilityHidden(data == nil)
    }

    private func draw(channel bins: [Int], color: Color, in context: inout GraphicsContext, size: CGSize) {
        guard let peak = bins.max(), peak > 0, bins.count > 1 else { return }
        let stepX = size.width / CGFloat(bins.count - 1)

        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, value) in bins.enumerated() {
            let x = CGFloat(index) * stepX
            let normalized = CGFloat(value) / CGFloat(peak)
            let y = size.height - normalized * size.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()

        context.fill(path, with: .color(color.opacity(0.55)))
    }
}
