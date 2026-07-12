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
    // パネル区切り線・グループ枠等に使う薄いボーダー色。
    // 0.08だとダークモードのツールバー背景（システムvibrancy、黒に近い）の上で
    // ほぼ不可視になり「区切り/枠が見えず要素が背景と被る」原因になっていた。
    // 実機（ライト/ダーク双方）でのコントラスト確認の結果、両モードで視認できる
    // 下限値として0.15に引き上げた（toolbar-native-chrome-round3.md 参照）。
    static let controlBorder = Color.primary.opacity(0.15)
}

// MARK: - ツールバーボタンスタイル（モード切替グループ専用）
//
// 以前は全ツールバーボタン（モード切替＋フォルダ/分析/共有）に同一の
// 「固定枠＋常時ボーダー」を適用していたが、Finder/写真.app等のネイティブ
// ツールバーでは単発アクションのプレーンアイコンボタンは枠を持たず、
// ホバー時のみシステムが自動でハイライトを出す。そのため本スタイルは
// **モード切替のようにグループ化されたセグメント的操作専用**とし、
// フォルダ・分析・共有等のprimaryAction配置には適用しない
// （それらは装飾なしのButton/Menuに戻し、システム標準ハイライトに委ねる）。

extension View {
    // モード切替グループ内の各ボタンの見た目（固定ヒットターゲット＋選択時のみ塗り）を適用する。
    // グループとしての一体感（外周の共有カプセル/矩形背景）は呼び出し側
    // （ContentView.swiftのHStack）が担当するため、個々のボタンには
    // 恒常的な枠を付けない。`Menu`のラベル等`ButtonStyle`が効かない箇所にも
    // 直接適用できるよう`ToolbarButtonStyle`本体からも切り出して共有している。
    func toolbarButtonAppearance(isSelected: Bool = false) -> some View {
        frame(width: 28, height: 22)
            .background(isSelected ? Color.onDarkCanvas.opacity(0.18) : Color.clear)
            .foregroundStyle(isSelected ? Color.onDarkCanvas : Color.onDarkCanvasSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
    }
}

// モード切替グループ内の各ボタンで共有するスタイル。個別ボタンに恒常的な
// 枠は持たせず、選択中のボタンのみアクセント色で塗って識別する。
// グループ全体の背景（セグメントコントロールらしい一体感）は呼び出し側の
// HStackが担当する。
struct ToolbarButtonStyle: ButtonStyle {
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .toolbarButtonAppearance(isSelected: isSelected)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
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
