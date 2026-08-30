import SwiftUI

/// カラーグレーディング用の色相・彩度ホイール。スライダーで精密な値も編集できる。
struct ColorWheelView: View {
    @Binding var component: ColorBalanceComponent
    let title: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ColorWheelCanvas(component: $component, title: title)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: ColorWheelLayout.diameter)

            AdjustmentSlider(label: "develop.colorGrading.hue", value: $component.hue, range: -180...180)
            AdjustmentSlider(label: "develop.colorGrading.saturation", value: $component.saturation, range: 0...100)
            AdjustmentSlider(label: "develop.colorGrading.lightness", value: $component.lightness)

            Button("develop.colorGrading.resetWheel") {
                component = .neutral
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(component.isNeutral)
        }
        .accessibilityElement(children: .contain)
    }
}

private enum ColorWheelLayout {
    static let diameter: CGFloat = 120
    static let handleDiameter: CGFloat = 14
    static let handleRingWidth: CGFloat = 1.5
    static let handleInnerRingInset: CGFloat = 1.5
    static let handleInnerRingDiameter = handleDiameter - handleInnerRingInset * 2
    static let handleShadowRadius: CGFloat = 2
    static let handleShadowYOffset: CGFloat = 1
    static let handleInnerRingOpacity = 0.7
    static let fullHueDegrees = 360.0
    static let saturationMaximum = 100.0
    static let handleBrightness = 1.0
    static let accessibilityHueStep = 5.0
}

private struct ColorWheelCanvas: View {
    @Binding var component: ColorBalanceComponent
    let title: LocalizedStringKey

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = diameter / 2

            ZStack {
                Circle()
                    .fill(colorWheelGradient)
                    .frame(width: diameter, height: diameter)
                    .position(center)
                Circle()
                    .fill(neutralCenterGradient(radius: radius))
                    .frame(width: diameter, height: diameter)
                    .position(center)
                handle(center: center, radius: radius)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(center: center, radius: radius))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? ColorWheelLayout.accessibilityHueStep : -ColorWheelLayout.accessibilityHueStep
                component.hue = min(max(component.hue + delta, -180), 180)
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: CornerRadius.small))
    }

    private var colorWheelGradient: AngularGradient {
        // hueRGB（ColorGradingFilter）のセクタ境界と一致させている。
        AngularGradient(
            colors: [.red, .yellow, .green, .cyan, .blue, Color(hue: 300.0 / 360.0, saturation: 1, brightness: 1), .red],
            center: .center
        )
    }

    private func neutralCenterGradient(radius: CGFloat) -> RadialGradient {
        RadialGradient(colors: [.white, .clear], center: .center, startRadius: 0, endRadius: radius)
    }

    private var accessibilityValue: Text {
        Text("H \(Int(component.hue))°  S \(Int(component.saturation))%")
    }

    private func handle(center: CGPoint, radius: CGFloat) -> some View {
        Circle()
            .fill(Color(
                // component.hue（-180...180、0=赤・時計回り）を色相環と同じ 0...1 の
                // 色相へラップする。ホイールのグラデーション・Color(hue:) いずれも赤を 0 に置くのでオフセット不要。
                hue: (component.hue + ColorWheelLayout.fullHueDegrees)
                    .truncatingRemainder(dividingBy: ColorWheelLayout.fullHueDegrees)
                    / ColorWheelLayout.fullHueDegrees,
                saturation: component.saturation / ColorWheelLayout.saturationMaximum,
                brightness: ColorWheelLayout.handleBrightness
            ))
            .frame(width: ColorWheelLayout.handleDiameter, height: ColorWheelLayout.handleDiameter)
            .overlay {
                Circle().strokeBorder(.white, lineWidth: ColorWheelLayout.handleRingWidth)
            }
            .overlay {
                Circle().strokeBorder(
                    .black.opacity(ColorWheelLayout.handleInnerRingOpacity),
                    lineWidth: ColorWheelLayout.handleRingWidth
                )
                .frame(
                    width: ColorWheelLayout.handleInnerRingDiameter,
                    height: ColorWheelLayout.handleInnerRingDiameter
                )
            }
            .shadow(radius: ColorWheelLayout.handleShadowRadius, y: ColorWheelLayout.handleShadowYOffset)
            .position(handlePosition(center: center, radius: radius))
    }

    private func dragGesture(center: CGPoint, radius: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                updateComponent(for: drag.location, center: center, radius: radius)
            }
    }

    private func updateComponent(for location: CGPoint, center: CGPoint, radius: CGFloat) {
        guard radius > 0 else { return }
        let horizontalDistance = location.x - center.x
        let verticalDistance = location.y - center.y
        let distance = hypot(horizontalDistance, verticalDistance)
        // atan2 の戻り値は [-π, π] なのでそのまま -180...180 度に収まる。
        component.hue = atan2(verticalDistance, horizontalDistance) * 180 / .pi
        component.saturation = min(distance / radius * 100, 100)
    }

    private func handlePosition(center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = component.hue * .pi / 180
        let distance = min(max(component.saturation, 0), 100) / 100 * radius
        return CGPoint(
            x: center.x + cos(angle) * distance,
            y: center.y + sin(angle) * distance
        )
    }
}
