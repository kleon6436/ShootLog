import SwiftUI

/// トーンカーブエディタ。RGB マスターと R/G/B チャンネル別を切り替えて編集する。
///
/// 制御点は正規化座標（x, y ∈ 0...1）。端点（x=0 / x=1）は y 方向のみ、
/// 中間点は x/y 両方向へドラッグできる。空き領域のクリックで点を追加、
/// 中間点のダブルクリックで削除する（最低 2 点は残す）。
struct ToneCurveEditorView: View {
    @Binding var rgb: [CurvePoint]
    @Binding var red: [CurvePoint]
    @Binding var green: [CurvePoint]
    @Binding var blue: [CurvePoint]

    @State private var channel: Channel = .rgb

    enum Channel: String, CaseIterable, Identifiable {
        case rgb, red, green, blue
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .rgb: "develop.toneCurve.channel.rgb"
            case .red: "develop.toneCurve.channel.red"
            case .green: "develop.toneCurve.channel.green"
            case .blue: "develop.toneCurve.channel.blue"
            }
        }

        var tint: Color {
            switch self {
            case .rgb: .primary
            case .red: .red
            case .green: .green
            case .blue: .blue
            }
        }
    }

    private var activePoints: Binding<[CurvePoint]> {
        switch channel {
        case .rgb: $rgb
        case .red: $red
        case .green: $green
        case .blue: $blue
        }
    }

    var body: some View {
        VStack(spacing: Spacing.small) {
            Picker("develop.toneCurve.channel", selection: $channel) {
                ForEach(Channel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            CurveCanvas(points: activePoints, tint: channel.tint)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 240)

            Button("develop.toneCurve.reset") {
                activePoints.wrappedValue = CurvePoint.identity
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(ToneCurve.isIdentity(activePoints.wrappedValue))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("develop.section.toneCurve")
    }
}

// MARK: - Canvas

private struct CurveCanvas: View {
    @Binding var points: [CurvePoint]
    let tint: Color

    private let handleSize: CGFloat = 10
    private let minSeparation: CGFloat = 0.02

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                grid
                referenceDiagonal(size: size)
                curvePath(size: size)
                    .stroke(tint, lineWidth: 1.5)
                handles(size: size)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                addPoint(at: location, size: size)
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: CornerRadius.small))
    }

    private var grid: some View {
        GeometryReader { geo in
            Path { path in
                for fraction in [0.25, 0.5, 0.75] {
                    let x = geo.size.width * fraction
                    let y = geo.size.height * fraction
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private func referenceDiagonal(size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: size.width, y: 0))
        }
        .stroke(.tertiary, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
    }

    private func curvePath(size: CGSize) -> Path {
        let sampleCount = 64
        let samples = ToneCurve.sampled(points, count: sampleCount)
        return Path { path in
            for (index, y) in samples.enumerated() {
                let px = size.width * CGFloat(index) / CGFloat(sampleCount - 1)
                let py = size.height * (1 - CGFloat(y))
                if index == 0 {
                    path.move(to: CGPoint(x: px, y: py))
                } else {
                    path.addLine(to: CGPoint(x: px, y: py))
                }
            }
        }
    }

    private func handles(size: CGSize) -> some View {
        ForEach(points.indices, id: \.self) { index in
            let point = points[index]
            Circle()
                .fill(tint)
                .frame(width: handleSize, height: handleSize)
                .position(
                    x: size.width * CGFloat(point.x),
                    y: size.height * (1 - CGFloat(point.y))
                )
                .gesture(dragGesture(index: index, size: size))
                .onTapGesture(count: 2) { removePoint(at: index) }
                .accessibilityElement()
                .accessibilityLabel("develop.toneCurve.point")
                .accessibilityValue(Text("\(Int(point.x * 255)), \(Int(point.y * 255))"))
                .accessibilityAdjustableAction { direction in
                    let delta = direction == .increment ? 0.04 : -0.04
                    let newY = min(max(point.y + delta, 0), 1)
                    points[index] = CurvePoint(x: point.x, y: newY)
                }
        }
    }

    private func dragGesture(index: Int, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard size.width > 0, size.height > 0 else { return }
                var nx = Double(min(max(drag.location.x / size.width, 0), 1))
                let ny = Double(min(max(1 - drag.location.y / size.height, 0), 1))

                let isEndpoint = index == 0 || index == points.count - 1
                if isEndpoint {
                    nx = points[index].x   // 端点は x を固定
                } else {
                    let lower = points[index - 1].x + Double(minSeparation)
                    let upper = points[index + 1].x - Double(minSeparation)
                    nx = min(max(nx, lower), upper)
                }
                points[index] = CurvePoint(x: nx, y: ny)
            }
    }

    private func addPoint(at location: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let nx = Double(min(max(location.x / size.width, 0), 1))
        let ny = Double(min(max(1 - location.y / size.height, 0), 1))
        let firstX = points.first?.x ?? 0
        let lastX = points.last?.x ?? 1
        guard nx > firstX + Double(minSeparation), nx < lastX - Double(minSeparation) else { return }
        guard let insertIndex = points.firstIndex(where: { $0.x > nx }) else { return }
        points.insert(CurvePoint(x: nx, y: ny), at: insertIndex)
    }

    private func removePoint(at index: Int) {
        guard points.count > 2, index != 0, index != points.count - 1 else { return }
        points.remove(at: index)
    }
}
