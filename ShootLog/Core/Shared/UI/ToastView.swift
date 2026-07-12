import SwiftUI

// 一時的な通知を表示するトーストビュー（2秒で自動消去）
struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassOrMaterialCapsule()
    }
}

// リキッドグラスヘルパー（glassOrMaterial 系）は DesignSystem.swift に移設。
// 同一モジュール内のためここでは import 不要でそのまま参照できる。
