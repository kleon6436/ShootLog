import SwiftUI

// MARK: - デザイントークン一元管理
//
// アプリ全体で散在していた角丸・シャドウ・フォント・黒背景用カラーを
// このファイルに集約する。値の変更はここ1箇所で行い、各Viewは
// トークンを参照するだけにする（Phase 3/5 で各Viewを順次移行）。

// MARK: - 角丸

// 散在していた 2/3/4/5/6/8/12/20pt を4段階に整理・集約したもの。
// マッピング方針:
//   2/3/4/5pt → small(4)   … コーナーハンドル・サムネイル枠・小バッジ等の微小角丸
//   6/8pt     → medium(8)  … ボタン・カード等の標準角丸（6は4と8の中間だがカード系は8へ寄せる）
//   12pt      → large(12)  … 大きめのパネル・コンテナ
//   20pt      → pill(20)   … 再生コントロール等のピル形状
enum CornerRadius {
    static let small: CGFloat = 4
    static let medium: CGFloat = 8
    static let large: CGFloat = 12
    static let pill: CGFloat = 20
}

// MARK: - 余白

// 散在していた 4/6/8/10/12pt のパディング値を5段階に整理・集約したもの。
// マッピング方針:
//   4pt  → xSmall(4)  … トグルボタン内の微小パディング
//   6pt  → small(6)   … ボタン間の狭い間隔（編集ツールバー内側等）
//   8pt  → medium(8)  … 標準間隔（グリッド外周・ボタン間隔の標準値）
//   10pt → large(10)  … パネル内余白・写真端からの距離
//   12pt → xLarge(12) … 大きめコンテナの外周
enum Spacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 6
    static let medium: CGFloat = 8
    static let large: CGFloat = 10
    static let xLarge: CGFloat = 12
}

// MARK: - 余白階層の方針（グリッド系レイアウト）
//
// Apple純正グリッド（写真.appのサムネイルグリッド等）は「セル間隔 < コンテナ
// 外周余白」で階層を作るのが通例。PhotoListView.swiftではグリッド外周
// padding・セル間隔spacingが現状同値(medium/8)で階層が無いため、外周側を
// large(10)またはxLarge(12)へ引き上げる方向で見直す
// （値の変更自体はPhotoListView.swift側のタスクで行う。ここでは方針のみ明記）。

// MARK: - シャドウ（Elevation）

// 既存の2箇所（CropOverlayView のコーナーハンドル、PhotoListView のお気に入りバッジ）の
// ドロップシャドウを単一トークンに統合したもの。どちらも黒背景/写真上に浮かぶ
// 小要素の視認性確保が目的で、パラメータがほぼ同一のため card に集約する。
enum Elevation {
    case card

    // シャドウ色
    var color: Color {
        switch self {
        case .card: Color.black.opacity(0.45)
        }
    }

    // ぼかし半径
    var radius: CGFloat {
        switch self {
        case .card: 2
        }
    }

    // 縦方向オフセット
    var yOffset: CGFloat {
        switch self {
        case .card: 1
        }
    }
}

extension View {
    // Elevation トークンを使ってドロップシャドウを適用する
    func elevation(_ elevation: Elevation) -> some View {
        shadow(color: elevation.color, radius: elevation.radius, x: 0, y: elevation.yOffset)
    }
}

// MARK: - HUD 用タイポグラフィ（固定サイズ）
//
// これらは意図的に Dynamic Type を使わない固定サイズフォント。
// フルスクリーン/スライドショー/トリミングオーバーレイなど、黒背景の
// 写真ビューア上に重ねる HUD オーバーレイ専用で、写真の上に一定サイズの
// コントロールとして表示する必要があるため。アプリの他画面（EXIFパネル・
// 分析・空状態等）は通常どおり Dynamic Type（.title2/.caption 等）を使う。
// この差異は設計上の意図であり、対応漏れではない。
enum HUDTypography {
    // キーボードヒント・秒数ラベル等の最小テキスト
    static let caption = Font.system(size: 10)
    // ページカウンター・速度切替等のラベル
    static let label = Font.system(size: 11, weight: .medium)
    // お気に入り・閉じる等のアイコン
    static let icon = Font.system(size: 16)
    // 前後ナビゲーション等の操作アイコン
    static let control = Font.system(size: 18, weight: .semibold)
    // 再生/一時停止等の主要操作アイコン
    static let controlLarge = Font.system(size: 20)
}

// MARK: - HUD 用ボタンスタイル

// 黒背景 HUD 上のボタン共通スタイル。ホバー時に円形ハイライト、押下時に軽く減光・縮小してネイティブな反応を出す。
// FullscreenModeView / SlideshowModeView で重複定義されていたものをここに集約。
struct HUDButtonStyle: ButtonStyle {
    var font: Font?

    func makeBody(configuration: Configuration) -> some View {
        // ButtonStyle（値型）は makeBody 内に直接 @State を持てないため、
        // ホバー状態の保持だけを目的に専用の View へ分離する
        HUDButtonBody(configuration: configuration, font: font)
    }
}

private struct HUDButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let font: Font?
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(font)
            // clipShape(Circle())等は見た目のクリップのみでヒットテストには影響しないため、
            // ここで明示的にラベル全体（frameで指定した矩形）をヒット領域にする
            .contentShape(Rectangle())
            // ホバー中は薄い白の円形ハイライトを背後に重ね、押せるボタンだと分かるようにする
            .background {
                Circle().fill(Color.white.opacity(isHovered ? 0.18 : 0))
            }
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.92 : (isHovered ? 1.06 : 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - 黒背景（ダークキャンバス）用カラー
//
// これらは意図的にセマンティック（ライト/ダーク適応）ではない固定色。
// 写真ビューアの黒背景（CLAUDE.md 規定により .black 固定が正）の上に乗る
// テキスト/アイコン用で、背景が固定である以上これらの前景色も固定でよい。
// 散在していた Color.white / .white.opacity(0.7) リテラルをここに集約し、
// 将来の調整を1箇所で行えるようにする（Phase 3 で各Viewを移行）。
extension Color {
    // 黒背景上の主要テキスト/アイコン色（Color.white の集約先）
    static let onDarkCanvas = Color.white
    // 黒背景上の副次/減光テキスト・アイコン色（.white.opacity(0.7) の集約先）
    static let onDarkCanvasSecondary = Color.white.opacity(0.7)
}

// MARK: - リキッドグラスヘルパー（同一モジュール内で使用可能）
//
// ToastView.swift から移設。責務の所在をデザインシステムに一元化する。
// macOS 26 以降はリキッドグラス、それ以前は Material でフォールバックする。

extension View {
    // macOS 26 以降はリキッドグラス、それ以前は regularMaterial で角丸背景
    @ViewBuilder
    func glassOrMaterial(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    // カプセル形状版
    @ViewBuilder
    func glassOrMaterialCapsule() -> some View {
        if #available(macOS 26, *) {
            self
                .foregroundStyle(.primary)
                .glassEffect(in: Capsule())
        } else {
            self
                .foregroundStyle(.white)
                .background(Color.black.opacity(0.75), in: Capsule())
        }
    }

    // 真円版（ナビゲーションボタン用）
    @ViewBuilder
    func glassOrMaterialCircle() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(in: Circle())
        } else {
            self
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
    }
}
