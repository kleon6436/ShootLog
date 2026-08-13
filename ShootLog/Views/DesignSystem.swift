import SwiftUI

// MARK: - デザイントークン一元管理
//
// アプリ全体で散在していた角丸・余白・シャドウ・フォントをこのファイルに集約する。
// 値の変更はここ1箇所で行い、各Viewはトークンを参照するだけにする。
// 色だけは Assets.xcassets/Colors/ の Color Set が定義元になる（後述のカラートークン節を参照）。

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

    // シャドウ色。ライト/ダークで濃度を変える必要があるため Color Set 側で定義する
    var color: Color {
        switch self {
        case .card: Color.cardShadow
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
            // ホバー中は円形ハイライトを背後に重ね、押せるボタンだと分かるようにする。
            // ハイライト色は外観で反転する（ライトでは暗く、ダークでは明るく乗せる）
            .background {
                Circle().fill(Color.hudHoverHighlight.opacity(isHovered ? 1 : 0))
            }
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.92 : (isHovered ? 1.06 : 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - カラートークン
//
// 色は Assets.xcassets/Colors/ の Color Set で定義し、ライト/ダークの2スロットを持たせる。
// Xcode が Color Set から Asset Symbol を自動生成するため、ここに手書きのアクセサは置かない
// （置くと `invalid redeclaration` でビルドが通らない）。各Viewからは自動生成された
// `Color.viewerCanvas` のようなプロパティを使う。Color Set 名のタイポは
// 自動生成シンボル経由なら実行時ではなくコンパイル時に検出される。
//
// 現在のトークンと用途:
//   ViewerCanvas             … 写真ビューアの背景。ライトは中間グレー、ダークは黒。
//                              ライトで純白を使わないのは、写真の白飛び・ハイライトを
//                              目視判定できなくなるため
//   OnViewerCanvas           … ビューア背景上の主要テキスト/アイコン色
//   OnViewerCanvasSecondary  … 同・副次/減光要素
//   CropMask                 … トリミング範囲外を覆うマスク。ライトでは背景が明るい分だけ薄くする
//   CardShadow               … Elevation.card のドロップシャドウ色。ライト背景では影を弱める
//   HUDHoverHighlight        … HUDボタンのホバーハイライト。ライトでは暗く、ダークでは明るく乗せる
//
// 写真ビューアの背景は以前 .black 固定だったが、その上に重ねる Material /
// Liquid Glass がシステム外観に追従するため、ライトモードでは「明るい背景に
// 白い前景」という判読不能な組み合わせが生じていた。背景側も外観追従にすることで、
// Material / Glass は自動的に正しい明度で描画され、前景色の指定だけで整合が取れる。

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

    // カプセル形状版。
    // 以前は macOS 26 未満で白文字＋黒背景を固定していたため、同じ部品が
    // OSバージョンによって正反対の配色になっていた。どちらの分岐も外観追従の
    // 背景＋ .primary の前景に統一する
    @ViewBuilder
    func glassOrMaterialCapsule() -> some View {
        if #available(macOS 26, *) {
            self
                .foregroundStyle(.primary)
                .glassEffect(in: Capsule())
        } else {
            self
                .foregroundStyle(.primary)
                .background(.regularMaterial, in: Capsule())
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
