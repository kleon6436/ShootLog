import SwiftUI

// フルスクリーン・スライドショー用のページドットインジケータ
struct PageDotsView: View {
    // 選択中写真が絞り込みで一覧から外れている場合は nil（どのドットも強調しない）
    let current: Int?
    let total: Int

    // 20枚超えはドットが多すぎるためカウンターのみにする
    private let dotsLimit = 20

    var body: some View {
        if total > 0 && total <= dotsLimit {
            HStack(spacing: 5) {
                ForEach(0..<total, id: \.self) { i in
                    Circle()
                        .fill(i == current ? Color.onViewerCanvas : Color.onViewerCanvas.opacity(0.3))
                        .frame(
                            width:  i == current ? 8 : 5,
                            height: i == current ? 8 : 5
                        )
                        .animation(.easeInOut(duration: 0.2), value: current)
                }
            }
        }
    }
}
