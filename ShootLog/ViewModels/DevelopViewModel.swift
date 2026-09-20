import AppKit
import Foundation
import ImageIO
// `Array.move(fromOffsets:toOffset:)`（`List.onMove` と同じ並べ替え意味論）のため。
import SwiftUI

/// サイドバーモードの現像編集パネルとビューアプレビューの状態を持つ ViewModel。
///
/// スライダーは `parameters` を直接書き換える。変更は自動で
/// プレビュー再描画（短いデバウンス）と永続化（長めのデバウンス）を予約する。
/// レンダリング自体は `ImageDeveloping` に委譲し、テストではスパイへ差し替える。
@Observable
@MainActor
final class DevelopViewModel {

    /// 作業中の調整値。UI からの変更点。
    var parameters: DevelopParameters = .neutral {
        didSet {
            guard !isApplyingLoadedState, parameters != oldValue else { return }
            scheduleRender()
            schedulePersist()
            // マスクオーバーレイの可視化は `masks` にしか依存しないため、露出等の無関係な
            // グローバル調整の変更では再合成しない（レビュー指摘: マスク編集中のスライダー
            // ドラッグのたびに Core Image の別ラウンドトリップが走っていた）。
            if maskEditMode, parameters.masks != oldValue.masks { scheduleMaskOverlayRender() }
        }
    }

    /// 現像適用済みのプレビュー。`nil` の間はベース画像（`PhotoImageViewModel`）を表示する。
    private(set) var previewImage: NSImage?
    /// 回転・トリミングだけを適用した比較用の編集前プレビュー。
    private(set) var beforeImage: NSImage?
    /// レンダリング中フラグ（スピナー表示用）。
    private(set) var isRendering = false
    /// 直近プレビューのヒストグラム。
    private(set) var histogram: HistogramData?
    /// 選択中写真が RAW か。
    private(set) var isRAW = false
    /// 撮影時ホワイトバランス。RAW ではデコーダーの実測値、非 RAW では推定値を保持する。
    private(set) var asShotWhiteBalance: WhiteBalanceSample?
    /// 撮影時ホワイトバランスの取得が完了したか。取得不能時も完了後は `true`。
    private(set) var isAsShotWhiteBalanceLoaded = false
    /// 撮影時ホワイトバランスの色温度。取得できない場合は `nil`。
    var asShotTemperatureKelvin: Double? { asShotWhiteBalance?.temperatureKelvin }
    /// 撮影時ホワイトバランスの色かぶり。取得できない場合は `nil`。
    var asShotTint: Double? { asShotWhiteBalance?.tint }
    /// 撮影時ホワイトバランスが推定値か。
    var asShotWhiteBalanceIsEstimated: Bool { asShotWhiteBalance?.isEstimated ?? false }
    /// true の間は現像前（回転・トリミングのみ反映）のベース画像を表示する。
    var isShowingBefore = false {
        didSet {
            guard isShowingBefore != oldValue else { return }
            if isShowingBefore {
                isComparingSplit = false
                maskEditMode = false
            }
        }
    }
    /// 現像編集の Before/After スプリット比較モード。
    var isComparingSplit = false {
        didSet {
            guard isComparingSplit != oldValue else { return }
            if isComparingSplit {
                guard previewImage != nil else {
                    isComparingSplit = false
                    return
                }
                isShowingBefore = false
                maskEditMode = false
                ensureBeforeImage()
            } else {
                beforeImageTask?.cancel()
                beforeImageTask = nil
            }
        }
    }
    /// マスク編集オーバーレイの表示・ハンドル操作モード。
    ///
    /// `previewImage == nil` の間は有効化できない。プレビューが無い間はビューアが
    /// ベース画像を描く別経路に落ちており、1 枚目のマスクを置いている最中に
    /// ハンドルの座標基準が入れ替わってしまうため（実装プラン §1.5.2）。
    var maskEditMode = false {
        didSet {
            guard maskEditMode != oldValue else { return }
            if maskEditMode {
                guard previewImage != nil else {
                    maskEditMode = false
                    return
                }
                isShowingBefore = false
                isComparingSplit = false
                scheduleMaskOverlayRender()
            } else {
                maskOverlayTask?.cancel()
                maskOverlayTask = nil
                maskOverlayImage = nil
                clearBrushTransientState()
            }
        }
    }
    /// 有効なマスクの合成結果を赤く着色したオーバーレイ。`maskEditMode` 中のみ非 nil。
    private(set) var maskOverlayImage: NSImage?
    /// UI のレイヤーリストで選択中のマスク。
    var selectedMaskLayerID: UUID? {
        didSet {
            guard selectedMaskLayerID != oldValue else { return }
            // 切り替え前のレイヤーへ描き続ける事故を防ぐため、選択が変わったらペイントを切る。
            isBrushPaintMode = false
        }
    }
    /// ビューア上のドラッグをブラシのペイントとして解釈するか。
    /// オーバーレイ（描画領域の出し分け）と現像パネル（ブラシ設定の開閉）で共有する。
    var isBrushPaintMode = false
    /// AI マスクを生成中か（ボタンの無効化・スピナー表示用）。
    private(set) var isGeneratingAIMask = false
    /// 直近の AI マスク生成が失敗した理由。成功・写真切り替え・次の生成開始で消える。
    private(set) var aiMaskGenerationFailureMessage: String?
    /// ブラシの半径。ベース空間の正規化座標（extent 短辺に対する比率）。
    var brushRadius: Double = DevelopViewModel.defaultBrushRadius
    /// ブラシの硬さ（0...100）。0 でソフト、100 でシャープ。
    var brushHardness: Double = 50
    /// ブラシの不透明度（0...100）。
    var brushOpacity: Double = 100
    /// true の間、次に描くストロークは消しゴム（減算）になる。
    var isBrushEraserMode = false
    /// ストローク上限に達して追加できなかったときのインライン通知。
    private(set) var brushStrokeLimitReachedMessage: String?
    /// スプリット境界の位置。表示中画像矩形内の 0...1（左端=0、右端=1）。
    var splitPosition: CGFloat = 0.5
    /// Auto WB の推定不能など、ホワイトバランス操作に対するインライン通知。
    private(set) var whiteBalanceStatusMessage: String?
    /// プレビュー上のクリッピング状態をビューア帯・ヒストグラム凡例に表示するか。
    /// 選択は UserDefaults(AppSettingsKeys.developClippingWarnings) へ永続化する。
    var showsClippingWarnings: Bool {
        didSet {
            guard showsClippingWarnings != oldValue else { return }
            UserDefaults.standard.set(showsClippingWarnings, forKey: AppSettingsKeys.developClippingWarnings)
        }
    }

    /// リセット可能か（何らかの調整が入っている）。
    var canReset: Bool { !parameters.isNeutral }

    /// 現在のマスクレイヤー一覧（表示順、index 0 が最下層）。
    var maskLayers: [MaskLayer] { parameters.masks }

    /// マスクを追加・編集できるか。ハンドルの初期配置にプレビューの表示基準が要る（§1.5.2）。
    var canEditMasks: Bool { previewImage != nil }

    /// マスクセクションを開いたタイミングで呼ぶ。
    ///
    /// `render()` は調整・回転・トリミングがすべて中立の場合、Core Image を介さない最適化で
    /// `previewImage` を作らず `nil` のままにする。マスク編集はそのジオメトリ基準を
    /// `previewImage` に依存するため、無調整の写真でマスクセクションを開くと `canEditMasks`
    /// が永遠に `false` のままとなり、マスク追加ボタンが無効化され続けていた
    /// （実機報告: 「Masks can be added once the preview is ready」から進めない）。
    /// この関数は中立時に限り一度だけベースプレビューを明示的に生成し、マスク編集を可能にする。
    func prepareMaskEditingPreviewIfNeeded() {
        guard previewImage == nil, !isRendering, let photo = currentPhoto else { return }
        guard parameters.isNeutral, rotation == 0, !Self.isEffectiveCrop(cropRect) else { return }

        isRendering = true
        let target = PhotoImageViewModel.targetMaxPixelSize(for: displaySize)
        let rot = rotation
        let crop = cropRect
        let colorSpace = previewColorSpace
        let usesToneMaskedColorGrading = toneMaskedColorGradingActive
        let generation = nextRenderGeneration()
        Task { [weak self] in
            guard let self else { return }
            let rendered = await self.engine.renderPreview(
                url: photo.fileURL,
                parameters: .neutral,
                targetMaxPixelSize: target,
                rotation: rot,
                cropRect: crop,
                previewColorSpace: colorSpace,
                useRAWParameterMapping: false,
                usesManualLensCorrection: false,
                usesToneMaskedColorGrading: usesToneMaskedColorGrading,
                asShotWhiteBalance: nil,
                maskRasters: [:]
            )
            guard generation == self.renderGeneration else { return }
            self.isRendering = false
            guard let rendered else { return }
            self.previewImage = NSImage(cgImage: rendered, size: .zero)
            if self.histogram == nil {
                self.histogram = await HistogramData.make(from: rendered)
            }
        }
    }

    /// RAW かつ `CIRAWFilter` 委譲が有効か（レンズ補正トグルなど RAW 固有 UI の表示条件）。
    var canDelegateToRAWFilter: Bool { rawMappingActive }

    /// 手動レンズ補正スライダーを編集できるか（schemaVersion 2 以降。RAW の CIRAWFilter 委譲中で
    /// レンズ補正トグル ON のときは CIRAWFilter 側が担うので不可）。
    var canEditManualLensCorrection: Bool {
        manualLensCorrectionActive && !(canDelegateToRAWFilter && parameters.lensCorrectionEnabled)
    }

    /// 保存済みプリセット（`ContentViewModel` が所有・写真をまたいで共有）。
    var presets: [DevelopPreset] { content?.developPresets ?? [] }

    /// プリセット適用・ペースト直前の状態。1 段だけ戻せる。
    private(set) var canUndo = false
    private var undoParameters: DevelopParameters?

    /// 「調整をペースト」に使えるクリップボードがあるか。
    private(set) var canPaste = false
    /// プロセス内の調整クリップボード。他アプリと互換性のない独自形式のため `NSPasteboard` は使わない。
    private static var clipboard: DevelopParameters?

    private let engine: any ImageDeveloping
    private let maskGenerator: any SubjectMaskGenerating
    private let content: ContentViewModel?

    /// `MaskRaster.pngData` のデコード結果。スライダー操作のたびに PNG を展開し直さないため、
    /// `rasterID` をキーに保持する。ラスタの中身は生成時に確定し以後変わらない（再生成は
    /// 新しい `rasterID` を発行する）ので、ID 一致だけで再利用してよい。写真切り替えで捨てる。
    private var maskRasterDecodeCache: [UUID: CGImage] = [:]

    /// ドラッグ中のストローク。確定（`endBrushStroke`）までレイヤーへは書き込まない。
    private var activeBrushStroke: BrushStroke?
    private var activeBrushLayerID: UUID?
    /// ブラシ専用の Undo 履歴。永続化せずメモリ内だけで持つ（写真切り替えで破棄）。
    private var brushUndoStack: [(layerID: UUID, previousBrushEdits: [BrushStroke])] = []

    private var currentPhoto: Photo?
    /// 写真切り替え検知用（`.task(id:)` 等、View 側は `currentPhoto` 自体に触れない）。
    var currentPhotoID: UUID? { currentPhoto?.id }
    private var displaySize: CGSize = .zero
    /// `EditInfo` 由来の回転角。プレビューにも焼き込む。
    private var rotation: Int = 0
    /// `EditInfo` 由来の正規化トリミング矩形（回転後の表示画像基準）。
    private var cropRect: CGRect?
    /// RAW の露出・WB を `CIRAWFilter` 側で解釈するか（`DevelopSettings.schemaVersion` >= 2 の RAW）。
    private var rawMappingActive = false
    /// 手動レンズ補正を解釈するか（`DevelopSettings.schemaVersion` >= 2）。
    private var manualLensCorrectionActive = false
    /// カラーグレーディングへトーン域マスク方式を適用するか（`DevelopSettings.schemaVersion` >= 5）。
    private var toneMaskedColorGradingActive = false
    /// 露出・色温度・色かぶりのスライダーをドラッグ中か。ドラッグ中は RAW 再デコードを避け、
    /// 標準チェーンで近似プレビューを出す。離した時点で `CIRAWFilter` 経路へ切り替えて描き直す。
    private var isRAWParameterDragging = false
    /// ドラッグ終了通知の取りこぼし対策。`Slider` の `onEditingChanged(false)` が届かないと
    /// ドラッグ状態が固着して `CIRAWFilter` 経路へ戻れなくなるため、一定時間で自動解除する。
    private var dragWatchdogTask: Task<Void, Never>?
    /// プレビュー CGImage の色空間。`nil` で sRGB。P3 ディスプレイ編集時にビューアが載っている
    /// ディスプレイの色空間を `setPreviewColorSpace` で渡すと、P3 書き出しと画面の見えが一致する。
    private var previewColorSpace: CGColorSpace?

    /// プレビューを engine でレンダーすべきか。現像調整または回転・トリミングのいずれかがある。
    private var shouldRender: Bool {
        !parameters.isNeutral || rotation != 0 || Self.isEffectiveCrop(cropRect)
    }

    /// 実質的なトリミング（全体矩形・退化矩形でない）か。
    static func isEffectiveCrop(_ rect: CGRect?) -> Bool {
        guard let rect else { return false }
        return rect != CGRect(x: 0, y: 0, width: 1, height: 1) && rect.width > 0 && rect.height > 0
    }
    /// `load` / `reset` による `parameters` 代入では didSet の副作用を抑止する。
    private var isApplyingLoadedState = false

    private var renderTask: Task<Void, Never>?
    private var histogramTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var beforeImageTask: Task<Void, Never>?
    private var beforeImageToken = 0
    private var maskOverlayTask: Task<Void, Never>?
    /// オーバーレイ要求の世代。await 明けにこれと一致しない結果は破棄する。
    private var maskOverlayGeneration = 0
    /// レンダー要求の世代。await 明けにこれと一致しない結果は破棄し、`isRendering` の後始末も
    /// 最新世代のみが行う（キャンセル・supersede でスピナーが残らないようにする）。
    private var renderGeneration = 0
    /// デバウンス待ちの保存内容（対象写真 ID と調整値）。写真切り替え時に取りこぼさないよう
    /// `load` の冒頭でこの内容を即時フラッシュする。
    private var pendingPersist: (photoID: UUID, parameters: DevelopParameters)?

    /// 連続操作をまとめる待ち時間。描画は体感優先で短く、保存は書き込み削減のため長めに取る。
    /// テストから短縮できるようにインスタンス値で持つ。
    private let renderDebounce: Duration
    private let persistDebounce: Duration
    /// ドラッグ終了を自動で確定させるまでの待ち時間。テストから短縮できるようにインスタンス値で持つ。
    private let dragWatchdogTimeout: Duration
    /// この画素数を超える表示領域の変化があったときだけ再デコードする。
    private static let displaySizeChangeThreshold: CGFloat = 32
    /// RAW の露出・WB を `CIRAWFilter` で再デコードする描画のデバウンス。標準チェーンより長く取る。
    private static let rawMappingDebounce: Duration = .milliseconds(180)
    /// マスクオーバーレイのデバウンス。現像プレビューとは別の engine ラウンドトリップなので
    /// 独立したタイマーで動かし、ハンドルドラッグ中はオーバーレイだけを追従させる（§1.5.4）。
    private static let maskOverlayDebounce: Duration = .milliseconds(60)

    init(
        engine: any ImageDeveloping = ImageDevelopmentEngine.shared,
        maskGenerator: any SubjectMaskGenerating = VisionSubjectMaskGenerator.shared,
        content: ContentViewModel?,
        renderDebounce: Duration = .milliseconds(60),
        persistDebounce: Duration = .milliseconds(500),
        dragWatchdogTimeout: Duration = .seconds(2)
    ) {
        self.engine = engine
        self.maskGenerator = maskGenerator
        self.content = content
        self.renderDebounce = renderDebounce
        self.persistDebounce = persistDebounce
        self.dragWatchdogTimeout = dragWatchdogTimeout
        self.showsClippingWarnings = UserDefaults.standard.object(forKey: AppSettingsKeys.developClippingWarnings) as? Bool
            ?? AppSettingsKeys.developClippingWarningsDefault
    }

    // MARK: - ライフサイクル

    /// 写真切り替え時に呼ぶ。保存済み調整値をロードし、調整または回転・トリミングがあれば即プレビューする。
    func load(photo: Photo?, displaySize: CGSize, rotation: Int = 0, cropRect: CGRect? = nil) {
        // 切り替え前の写真のデバウンス保存を取りこぼさないよう、先にフラッシュする。
        flushPendingPersist()
        collectOrphanedMaskRastersForLeavingPhoto()
        renderTask?.cancel()
        histogramTask?.cancel()
        invalidateBeforeImage()
        _ = nextRenderGeneration()
        if displaySize.width > 0, displaySize.height > 0 { self.displaySize = displaySize }
        currentPhoto = photo
        self.rotation = rotation
        self.cropRect = cropRect

        isApplyingLoadedState = true
        parameters = content?.currentDevelopSettings?.parameters ?? .neutral
        isApplyingLoadedState = false

        undoParameters = nil
        canUndo = false
        canPaste = Self.clipboard != nil
        clearPreview()
        histogram = nil
        isRendering = false
        isShowingBefore = false
        splitPosition = 0.5
        selectedMaskLayerID = nil
        // 別写真のラスタが混入しないよう、写真ごとにデコード結果を捨てる。
        maskRasterDecodeCache.removeAll()
        clearBrushTransientState()
        aiMaskGenerationFailureMessage = nil
        dragWatchdogTask?.cancel()
        dragWatchdogTask = nil
        isRAWParameterDragging = false
        isRAW = photo.map { engine.isRAW(url: $0.fileURL) } ?? false
        asShotWhiteBalance = nil
        isAsShotWhiteBalanceLoaded = false
        // version 1 の既存 RAW レコードは標準チェーンのまま（色が変わらないように）。
        // レコードが無い新規は version 2 相当として委譲する。
        rawMappingActive = isRAW && (content?.currentDevelopSettings?.usesRAWParameterMapping ?? true)
        manualLensCorrectionActive = content?.currentDevelopSettings?.usesManualLensCorrection ?? true
        toneMaskedColorGradingActive = content?.currentDevelopSettings?.usesToneMaskedColorGrading ?? true

        if let photo {
            Task { [weak self] in
                guard let self else { return }
                let sample = if let content = self.content {
                    await content.asShotWhiteBalance(for: photo)
                } else {
                    await self.engine.asShotNeutral(for: photo.fileURL)
                }
                guard self.currentPhoto?.id == photo.id else { return }
                self.isAsShotWhiteBalanceLoaded = true
                if let sample {
                    self.applyAsShotWhiteBalance(sample)
                }
            }
            if shouldRender {
                let params = parameters
                let rot = rotation
                let crop = cropRect
                let mapping = rawMappingActive
                let manualLensCorrection = shouldApplyManualLensCorrection(params)
                let usesToneMaskedColorGrading = toneMaskedColorGradingActive
                let asShot = usesToneMaskedColorGrading ? asShotWhiteBalance : nil
                let generation = renderGeneration
                renderTask = Task { [weak self] in
                    await self?.render(
                        photo: photo, parameters: params, rotation: rot, cropRect: crop,
                        useRAWParameterMapping: mapping, usesManualLensCorrection: manualLensCorrection,
                        usesToneMaskedColorGrading: usesToneMaskedColorGrading,
                        asShotWhiteBalance: asShot,
                        generation: generation
                    )
                }
            } else {
                scheduleHistogramOnly(generation: renderGeneration)
            }
        }
    }

    /// 露出・色温度・色かぶりのスライダーのドラッグ状態を伝える。
    /// ドラッグ中は RAW 再デコードを避けて標準チェーンで近似し、離した時点で `CIRAWFilter` 経路で描き直す。
    /// `onEditingChanged(false)` が届かない場合に備え、ドラッグ開始からの経過時間で自動的に終了扱いにする。
    func setRAWParameterDragging(_ dragging: Bool) {
        guard rawMappingActive else { return }
        if dragging {
            // ドラッグ開始が連続で届いても監視が途切れないよう、状態変化の有無に関わらず張り直す。
            dragWatchdogTask?.cancel()
            dragWatchdogTask = Task { [weak self] in
                guard let timeout = self?.dragWatchdogTimeout else { return }
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.setRAWParameterDragging(false)
            }
            isRAWParameterDragging = true
        } else {
            dragWatchdogTask?.cancel()
            dragWatchdogTask = nil
            guard isRAWParameterDragging else { return }
            isRAWParameterDragging = false
            // ドラッグ終了時のみ再レンダー（開始時は didSet 側の描画に任せる）。
            if currentPhoto != nil, shouldRender { scheduleRender() }
        }
    }

    func selectWhiteBalanceMode(_ mode: WhiteBalanceSettings.Mode) {
        switch mode {
        case .custom:
            let baseK = asShotWhiteBalance?.temperatureKelvin ?? 6_500
            let baseTint = asShotWhiteBalance?.tint ?? 0
            var seeded = WhiteBalanceSettings(mode: mode, temperatureKelvin: baseK, tint: baseTint)
            seeded.normalize()
            parameters.whiteBalance = seeded
        case .auto:
            // Picker を即座に確定しつつ、計算完了までの中間フレームが恒等になるよう
            // as-shot 値でシードする（mode だけ変えると hasEffect が立ち一瞬色が飛ぶ）。
            // 推定失敗時は切り替え前の設定へ戻す。
            let previous = parameters.whiteBalance
            let baseK = asShotWhiteBalance?.temperatureKelvin ?? 6_500
            let baseTint = asShotWhiteBalance?.tint ?? 0
            var seeded = WhiteBalanceSettings(mode: .auto, temperatureKelvin: baseK, tint: baseTint)
            seeded.normalize()
            parameters.whiteBalance = seeded
            applyAutomaticWhiteBalance(restoringOnFailureTo: previous)
        default:
            parameters.whiteBalance = WhiteBalanceSettings.preset(mode)
        }
    }

    /// ホワイトバランスの色温度を変更する。As Shot からの初回編集時は撮影時値を基準に Custom へ切り替える。
    func setWhiteBalanceTemperature(_ kelvin: Double) {
        if parameters.whiteBalance.mode == .asShot {
            let baseTint = asShotWhiteBalance?.tint ?? 0
            var whiteBalance = WhiteBalanceSettings(mode: .custom, temperatureKelvin: kelvin, tint: baseTint)
            whiteBalance.normalize()
            parameters.whiteBalance = whiteBalance
        } else {
            parameters.whiteBalance.mode = .custom
            parameters.whiteBalance.temperatureKelvin = kelvin
            parameters.whiteBalance.normalize()
        }
    }

    /// ホワイトバランスの色かぶりを変更する。As Shot からの初回編集時は撮影時値を基準に Custom へ切り替える。
    func setWhiteBalanceTint(_ value: Double) {
        if parameters.whiteBalance.mode == .asShot {
            let baseK = asShotWhiteBalance?.temperatureKelvin ?? 6_500
            var whiteBalance = WhiteBalanceSettings(mode: .custom, temperatureKelvin: baseK, tint: value)
            whiteBalance.normalize()
            parameters.whiteBalance = whiteBalance
        } else {
            parameters.whiteBalance.mode = .custom
            parameters.whiteBalance.tint = value
            parameters.whiteBalance.normalize()
        }
    }

    /// グレーワールド推定でホワイトバランスを合わせる。
    /// - Parameter restoringOnFailureTo: 推定失敗時に戻す設定。`nil` なら呼び出し時点の設定へ戻す
    ///   （mode だけ `.asShot` へ倒すとユーザーが入力した数値が死ぬため丸ごと復元する）。
    func applyAutomaticWhiteBalance(restoringOnFailureTo restoreTarget: WhiteBalanceSettings? = nil) {
        guard let photo = currentPhoto else { return }
        let photoID = photo.id
        let previousWhiteBalance = restoreTarget ?? parameters.whiteBalance
        let target = PhotoImageViewModel.targetMaxPixelSize(for: displaySize)
        Task { [weak self] in
            guard let self else { return }
            let source = await self.engine.renderPreview(
                url: photo.fileURL,
                parameters: .neutral,
                targetMaxPixelSize: target,
                rotation: self.rotation,
                cropRect: self.cropRect,
                previewColorSpace: self.previewColorSpace,
                useRAWParameterMapping: false,
                usesManualLensCorrection: false,
                usesToneMaskedColorGrading: false,
                asShotWhiteBalance: nil,
                maskRasters: resolvedMaskRasters(for: .neutral)
            )
            guard self.currentPhoto?.id == photoID else { return }
            guard let source,
                  let settings = WhiteBalanceResolver.automaticSettings(from: source) else {
                self.whiteBalanceStatusMessage = String(localized: "develop.whiteBalance.autoUnavailable")
                self.parameters.whiteBalance = previousWhiteBalance
                return
            }
            if !self.isAsShotWhiteBalanceLoaded {
                let fetchedAsShot = if let content = self.content {
                    await content.asShotWhiteBalance(for: photo)
                } else {
                    await self.engine.asShotNeutral(for: photo.fileURL)
                }
                guard self.currentPhoto?.id == photoID else { return }
                self.asShotWhiteBalance = fetchedAsShot
                self.isAsShotWhiteBalanceLoaded = true
            }
            self.whiteBalanceStatusMessage = nil
            let baseK = self.asShotWhiteBalance?.temperatureKelvin ?? 6_500
            let baseTint = self.asShotWhiteBalance?.tint ?? 0
            var seeded = settings
            seeded.temperatureKelvin = baseK + (settings.temperatureKelvin - 6_500)
            seeded.tint = baseTint + settings.tint
            seeded.mode = .auto
            seeded.normalize()
            self.parameters.whiteBalance = seeded
        }
    }

    func toggleBeforeAfter() {
        isShowingBefore.toggle()
    }

    /// 現像済みプレビューと編集前プレビューの左右分割表示を切り替える。
    func toggleSplitCompare() {
        guard previewImage != nil else {
            isComparingSplit = false
            return
        }
        isComparingSplit.toggle()
    }

    /// 回転・トリミングの変更を受けて再レンダーする。調整も幾何変換も無くなればプレビューを解除する。
    func updateEditGeometry(rotation: Int, cropRect: CGRect?) {
        guard rotation != self.rotation || cropRect != self.cropRect else { return }
        self.rotation = rotation
        self.cropRect = cropRect
        guard currentPhoto != nil else { return }
        let wasComparingSplit = isComparingSplit
        invalidateBeforeImage()
        if shouldRender {
            scheduleRender()
            if wasComparingSplit {
                ensureBeforeImage()
            }
            // オーバーレイは回転・トリミングを焼き込んだ画像なので、幾何が変われば描き直す。
            if maskEditMode { scheduleMaskOverlayRender() }
        } else {
            renderTask?.cancel()
            histogramTask?.cancel()
            _ = nextRenderGeneration()
            clearPreview()
            scheduleHistogramOnly(generation: renderGeneration)
            isRendering = false
        }
    }

    /// ビューアが載っているディスプレイの色空間を伝える。P3 ディスプレイなら P3 を渡すと
    /// プレビューが P3 書き出しの見えと一致する。`nil` で sRGB。変化があれば再描画する。
    func setPreviewColorSpace(_ colorSpace: CGColorSpace?) {
        guard !Self.sameColorSpace(colorSpace, previewColorSpace) else { return }
        let wasComparingSplit = isComparingSplit
        previewColorSpace = colorSpace
        invalidateBeforeImage()
        if currentPhoto != nil, shouldRender {
            scheduleRender()
            if wasComparingSplit {
                ensureBeforeImage()
            }
        } else {
            clearPreview()
        }
    }

    /// `CGColorSpace` は `Equatable` ではないため `CFEqual` で比較する。
    private static func sameColorSpace(_ lhs: CGColorSpace?, _ rhs: CGColorSpace?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?): return CFEqual(left, right)
        default: return false
        }
    }

    /// ビューア領域のサイズ変化を伝える。大きく変わったときだけ再描画する。
    func updateDisplaySize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = abs(size.width - displaySize.width) > Self.displaySizeChangeThreshold
            || abs(size.height - displaySize.height) > Self.displaySizeChangeThreshold
        displaySize = size
        guard changed else { return }
        let wasComparingSplit = isComparingSplit
        invalidateBeforeImage()
        if changed, currentPhoto != nil, shouldRender {
            scheduleRender()
            if wasComparingSplit {
                ensureBeforeImage()
            }
        } else if changed, currentPhoto != nil {
            clearPreview()
            scheduleHistogramOnly(generation: renderGeneration)
        }
    }

    /// 現像調整を全て取り消す。回転・トリミング（`ContentViewModel.resetEdits`）には影響しない。
    /// 回転・トリミングが残っていれば、それだけを焼き込んだプレビューを出し直す。
    func reset() {
        renderTask?.cancel()
        histogramTask?.cancel()
        // resetDevelop がレコードを消すので、保留中の保存はフラッシュせず破棄する。
        persistTask?.cancel()
        pendingPersist = nil
        invalidateBeforeImage()
        _ = nextRenderGeneration()
        isApplyingLoadedState = true
        parameters = .neutral
        isApplyingLoadedState = false
        clearPreview()
        histogram = nil
        isRendering = false
        content?.resetDevelop()
        // reset で旧レコードは削除され、次の保存は schemaVersion 5（RAW は露出・WB 委譲も有効）。
        manualLensCorrectionActive = true
        rawMappingActive = isRAW
        toneMaskedColorGradingActive = true
        selectedMaskLayerID = nil
        clearBrushTransientState()
        undoParameters = nil
        canUndo = false
        if currentPhoto != nil, shouldRender {
            scheduleRender()
        } else if currentPhoto != nil {
            scheduleHistogramOnly(generation: renderGeneration)
        }
    }

    /// `reset()` を呼ぶ前に確認ダイアログを出すべきか。マスクレイヤーを 1 枚以上持つ場合、
    /// AI マスク生成やブラシ作業を確認なしで破棄させないため。
    var resetRequiresConfirmation: Bool { !maskLayers.isEmpty }

    /// セクション単位で調整を中立へ戻す。didSet 経由でプレビュー再描画・保存が予約される。
    func resetSection(_ section: DevelopSection) {
        guard parameters.isModified(in: section) else { return }
        parameters.reset(section)
    }

    // MARK: - プリセット / コピー & ペースト

    /// 現在の調整値をプリセットとして保存する。
    /// - Parameter includeMasks: `true` ならマスクレイヤーも含めて保存する。既定 `false`
    ///   （放射状マスクの位置は写真ごとに意味が変わるため、既定では含めない）。
    ///   AI マスクは `includeMasks` の値によらず常に除外する（`applyPreset`参照。ラスタが
    ///   元写真にしか無く、別写真への適用時に複製できないため、保存時点で持たせない）。
    func saveCurrentAsPreset(name: String, includeMasks: Bool = false) {
        var toSave = parameters
        if !includeMasks {
            toSave.masks = []
        } else {
            toSave.masks = toSave.masks.filter { layer in
                if case .ai = layer.source { return false }
                return true
            }
        }
        content?.saveDevelopPreset(name: name, from: toSave)
    }

    func deletePreset(_ preset: DevelopPreset) {
        content?.deleteDevelopPreset(preset)
    }

    func renamePreset(_ preset: DevelopPreset, to name: String) {
        content?.renameDevelopPreset(preset, to: name)
    }

    /// プリセットの調整値を適用する。直前の状態は 1 段だけ戻せる。
    /// - Parameters:
    ///   - relative: `true` なら現在の調整値へプリセットを差分として重ねる（露出違いの
    ///     複数カットへ同じスタイルを崩さず足せる）。`false`（既定）なら丸ごと置き換える。
    ///   - includeMasks: `true` ならプリセット側のマスクも反映する。既定 `false` の場合、
    ///     `relative: true` ではプリセット側マスクを追記せず、`relative: false` では
    ///     現在のマスクレイヤーをそのまま保持する（プリセットで上書きしない）。
    ///
    ///     `includeMasks: true` でも AI マスクは常に除外する（`pasteAdjustments` と同じ理由、
    ///     プラン§3.6）。`DevelopPreset` は写真をまたいで使うのが本来の用途であり、AI マスクの
    ///     ラスタは元写真の `DevelopSettings.maskRasters` にしか存在しないため、別写真への適用時
    ///     ほぼ確実にラスタを複製できない（レビューで指摘された「fallback が実質常用パス化する」
    ///     問題）。グラデーション・輝度レンジは幾何・数値パラメータのみで写真間の意味が保たれる
    ///     ため、`.ai` だけを除いて含める。
    func applyPreset(_ preset: DevelopPreset, relative: Bool = false, includeMasks: Bool = false) {
        var presetParams = preset.parameters
        presetParams.masks = presetParams.masks.filter { layer in
            if case .ai = layer.source { return false }
            return true
        }
        if !includeMasks {
            presetParams.masks = relative ? [] : parameters.masks
        }
        // 取り込んだマスクは末尾に積まれる（relative は追記、丸ごと置き換えは全部が外来）。
        // .ai は上で除外済みなので実際にはno-opになるが、防御的に残す（§3.2参照整合性ケース3）。
        let foreignMasksFrom = includeMasks ? (relative ? parameters.masks.count : 0) : nil
        let target = relative ? parameters.applying(delta: presetParams) : presetParams
        applyReplacingParameters(target, duplicatingAIMaskRastersFrom: foreignMasksFrom)
    }

    /// 現在の調整値をクリップボードへコピーする。
    func copyAdjustments() {
        Self.clipboard = parameters
        canPaste = true
    }

    /// クリップボードの調整値を適用する。直前の状態は 1 段だけ戻せる。
    /// AI マスクは既定で含めない（被写体位置が違う写真へラスタを貼るとほぼ確実に不正になるため。
    /// グラデーション・輝度レンジは同一シーンの連写へ渡す用途が主なので含める。プラン §3.6）。
    func pasteAdjustments() {
        guard let clip = Self.clipboard else { return }
        var filtered = clip
        filtered.masks = clip.masks.filter { layer in
            if case .ai = layer.source { return false }
            return true
        }
        applyReplacingParameters(filtered, duplicatingAIMaskRastersFrom: 0)
    }

    /// プリセット適用・ペーストを 1 段だけ取り消す。
    func undoLastApply() {
        guard let target = undoParameters else { return }
        undoParameters = nil
        canUndo = false
        parameters = target
    }

    /// `parameters` を丸ごと差し替える。didSet でプレビュー再描画・永続化が予約される。
    /// - Parameter index: 取り込んだ（＝この写真のものではない）マスクレイヤーの開始位置。
    ///   指定すると、そこから末尾までの AI マスクのラスタを複製してから差し替える。
    private func applyReplacingParameters(_ new: DevelopParameters, duplicatingAIMaskRastersFrom index: Int? = nil) {
        guard new != parameters else { return }
        var target = new
        if let index { duplicateAIMaskRasters(in: &target, from: index) }
        undoParameters = parameters
        canUndo = true
        parameters = target
    }

    /// プリセット/ペーストで取り込んだ AI マスクレイヤーの `rasterID` を再発行し、`MaskRaster` を複製する。
    ///
    /// `MaskLayer.id` だけを再発行すると 2 レイヤーが 1 つの `MaskRaster` を指し、片方を消したときの
    /// GC が他方のラスタを持っていってしまう（§3.2 参照整合性ケース 3）。
    ///
    /// 複製元が見つからない場合（他写真で作ったラスタを指すプリセットなど）は `.ai` のまま残す。
    /// 未解決の `rasterID` は描画側で全面 0 として扱われて実害が無く、レイヤー種別を保てば
    /// この写真向けの「再生成」導線をそのまま使えるため。
    private func duplicateAIMaskRasters(in parameters: inout DevelopParameters, from index: Int) {
        guard index < parameters.masks.count, let settings = content?.currentDevelopSettings else { return }
        for position in index..<parameters.masks.count {
            guard case .ai(var reference) = parameters.masks[position].source,
                  let original = settings.maskRasters.first(where: { $0.id == reference.rasterID })
            else { continue }
            let duplicated = MaskRaster(id: UUID(), pngData: original.pngData, longEdge: original.longEdge)
            settings.maskRasters.append(duplicated)
            reference.rasterID = duplicated.id
            parameters.masks[position].source = .ai(reference)
        }
    }

    // MARK: - マスク（ローカル調整）

    /// 線形グラデーションのマスクレイヤーを 1 枚追加し、選択状態にする。
    /// プレビューが出ていない間は何もしない（§1.5.2）。
    /// - Returns: 追加したレイヤーの ID。追加しなかった場合は `nil`。
    @discardableResult
    func addLinearGradientMask() -> UUID? {
        guard canEditMasks else { return nil }
        let layer = MaskLayer(
            id: UUID(),
            name: String(format: String(localized: "develop.mask.defaultName"), Int64(parameters.masks.count + 1)),
            source: .linearGradient(LinearGradientMask(
                start: NormalizedPoint(x: 0.3, y: 0.5),
                end: NormalizedPoint(x: 0.7, y: 0.5)
            )),
            adjustments: LocalAdjustments()
        )
        var updated = parameters
        updated.masks.append(layer)
        parameters = updated
        selectedMaskLayerID = layer.id
        return layer.id
    }

    /// 放射状グラデーションのマスクレイヤーを 1 枚追加し、選択状態にする。
    /// - Returns: 追加したレイヤーの ID。追加しなかった場合は `nil`。
    @discardableResult
    func addRadialGradientMask() -> UUID? {
        guard canEditMasks else { return nil }
        let layer = MaskLayer(
            id: UUID(),
            name: String(format: String(localized: "develop.mask.defaultName"), Int64(parameters.masks.count + 1)),
            source: .radialGradient(RadialGradientMask(
                center: NormalizedPoint(x: 0.5, y: 0.5),
                radius: 0.3,
                aspectRatio: 1.0,
                rotationDegrees: 0,
                falloff: 50
            )),
            adjustments: LocalAdjustments()
        )
        var updated = parameters
        updated.masks.append(layer)
        parameters = updated
        selectedMaskLayerID = layer.id
        return layer.id
    }

    /// 輝度レンジのマスクレイヤーを 1 枚追加し、選択状態にする。
    /// 既定は「明るい部分」の選択（空マスクの代替という主用途に寄せた初期値）。
    /// - Returns: 追加したレイヤーの ID。追加しなかった場合は `nil`。
    @discardableResult
    func addLuminanceRangeMask() -> UUID? {
        guard canEditMasks else { return nil }
        let layer = MaskLayer(
            id: UUID(),
            name: String(format: String(localized: "develop.mask.defaultName"), Int64(parameters.masks.count + 1)),
            source: .luminanceRange(LuminanceRangeMask(
                lowerBound: 0.6,
                upperBound: 1.0,
                smoothness: 30
            )),
            adjustments: LocalAdjustments()
        )
        var updated = parameters
        updated.masks.append(layer)
        parameters = updated
        selectedMaskLayerID = layer.id
        return layer.id
    }

    /// ブラシだけで描くマスクレイヤーを 1 枚追加し、選択したうえでペイントモードへ入る。
    /// ベースは全面 0（`.none`）なので、追加直後は何も塗られていない状態から始まる。
    /// - Returns: 追加したレイヤーの ID。追加しなかった場合は `nil`。
    @discardableResult
    func addBrushMask() -> UUID? {
        guard canEditMasks else { return nil }
        let layer = MaskLayer(
            id: UUID(),
            name: String(
                format: String(localized: "develop.mask.brush.defaultName"),
                Int64(parameters.masks.count + 1)
            ),
            source: .none,
            adjustments: LocalAdjustments()
        )
        var updated = parameters
        updated.masks.append(layer)
        parameters = updated
        selectedMaskLayerID = layer.id
        isBrushPaintMode = true
        return layer.id
    }

    /// 指定したマスクレイヤーを削除する。
    /// プレビューの有無でゲートしない。レンダー失敗などで `previewImage` が消えた状態から
    /// 抜け出す唯一の手段が削除のため。
    func removeMask(id: UUID) {
        guard parameters.masks.contains(where: { $0.id == id }) else { return }
        var updated = parameters
        updated.masks.removeAll { $0.id == id }
        parameters = updated
        if selectedMaskLayerID == id { selectedMaskLayerID = nil }
        // 消えたレイヤーを指す Undo エントリ・進行中ストロークは復元先が無い。
        brushUndoStack.removeAll { $0.layerID == id }
        if activeBrushLayerID == id {
            activeBrushStroke = nil
            activeBrushLayerID = nil
        }
    }

    /// マスクレイヤーの表示順を並べ替える。index 0 が最下層のまま、配列の並びを直接操作する。
    /// `List.onMove` のシグネチャに合わせてある。
    func moveMasks(from source: IndexSet, to destination: Int) {
        guard canEditMasks else { return }
        var updated = parameters
        updated.masks.move(fromOffsets: source, toOffset: destination)
        guard updated != parameters else { return }
        parameters = updated
    }

    /// 指定したマスクレイヤーをその場で書き換える。`parameters` 経由で代入するため、
    /// 再描画と永続化は既存の didSet が予約する。
    func updateMask(id: UUID, _ transform: (inout MaskLayer) -> Void) {
        guard let index = parameters.masks.firstIndex(where: { $0.id == id }) else { return }
        var updated = parameters
        transform(&updated.masks[index])
        guard updated != parameters else { return }
        parameters = updated
    }

    // MARK: - ブラシ

    /// ブラシ半径として許容する範囲（ベース空間の正規化座標、短辺基準）。
    static let brushRadiusRange: ClosedRange<Double> = 0.005...0.3

    /// ブラシ半径の既定値。スライダーのリセット先も兼ねる。
    static let defaultBrushRadius = 0.03

    /// 点間引きのしきい値。ブラシ半径に対する比率と絶対上限の小さい方を使う。
    ///
    /// 比率だけだと大きなブラシで間引きが粗くなりすぎ、「ストローク形状の最大偏差が長辺の
    /// 0.2% 以内」という受け入れ基準を割る（落とした点は直前の採用点から高々しきい値ぶん
    /// しか離れていないので、しきい値がそのまま偏差の上界になる）。逆に絶対値だけだと
    /// 細いブラシで無駄に点が増える。
    private static let brushPointMinimumDistanceRatio = 0.15
    /// 点間引きしきい値の絶対上限（正規化座標）。受け入れ基準の 0.2% をそのまま採る。
    private static let brushPointMaximumSpacing = 0.002
    /// 1 レイヤーあたりのストローク上限。超過時は自動ラスタ化せず警告だけ出す（OQ-4）。
    private static let maxBrushStrokesPerLayer = 500
    /// ブラシ Undo の履歴保持数。
    private static let maxBrushUndoDepth = 20

    /// 直前のブラシストロークを取り消せるか。
    var canUndoBrushStroke: Bool { !brushUndoStack.isEmpty }

    /// ドラッグ開始時に呼ぶ。新しいストロークを開始する。
    /// - Parameters:
    ///   - point: ベース空間の正規化座標（最初の点）。
    ///   - layerID: ストロークを追加する対象レイヤー。
    func beginBrushStroke(at point: NormalizedPoint, layerID: UUID) {
        guard canEditMasks, parameters.masks.contains(where: { $0.id == layerID }) else { return }
        activeBrushStroke = BrushStroke(
            points: [BrushPoint(x: point.x, y: point.y)],
            radius: brushRadius,
            hardness: brushHardness,
            opacity: brushOpacity,
            isEraser: isBrushEraserMode
        )
        activeBrushLayerID = layerID
    }

    /// ドラッグ中に呼ぶ。直前の採用点から十分離れている場合だけ点を追加する。
    func continueBrushStroke(at point: NormalizedPoint) {
        guard var stroke = activeBrushStroke, let last = stroke.points.last else { return }
        let dx = point.x - last.x
        let dy = point.y - last.y
        guard (dx * dx + dy * dy).squareRoot() > Self.brushPointSpacing(forRadius: stroke.radius) else { return }
        stroke.points.append(BrushPoint(x: point.x, y: point.y))
        activeBrushStroke = stroke
    }

    /// ドラッグ終了時に呼ぶ。ストロークを確定し、対象レイヤーの `brushEdits` へ追加する。
    /// 上限に達している場合は追加せず、警告メッセージだけを出す（OQ-4: 自動ラスタ化はしない）。
    func endBrushStroke() {
        defer {
            activeBrushStroke = nil
            activeBrushLayerID = nil
        }
        guard let stroke = activeBrushStroke, let layerID = activeBrushLayerID,
              let layer = parameters.masks.first(where: { $0.id == layerID }) else { return }
        guard layer.brushEdits.count < Self.maxBrushStrokesPerLayer else {
            brushStrokeLimitReachedMessage = String(localized: "develop.mask.brush.limitReached")
            return
        }
        brushUndoStack.append((layerID: layerID, previousBrushEdits: layer.brushEdits))
        if brushUndoStack.count > Self.maxBrushUndoDepth {
            brushUndoStack.removeFirst()
        }
        updateMask(id: layerID) { $0.brushEdits.append(stroke) }
        brushStrokeLimitReachedMessage = nil
    }

    /// 直前のブラシストロークを取り消す（非永続、ViewModel 内のみ）。
    func undoLastBrushStroke() {
        guard let last = brushUndoStack.popLast() else { return }
        updateMask(id: last.layerID) { $0.brushEdits = last.previousBrushEdits }
        brushStrokeLimitReachedMessage = nil
    }

    /// 指定半径での点間引きしきい値。
    private static func brushPointSpacing(forRadius radius: Double) -> Double {
        min(brushPointMinimumDistanceRatio * max(radius, brushRadiusRange.lowerBound), brushPointMaximumSpacing)
    }

    /// 進行中ストローク・Undo 履歴・警告を捨てる。写真切り替えやマスク編集終了で呼ぶ。
    /// 別写真の `brushEdits` を誤って復元しないため、写真をまたいで持ち越してはならない。
    private func clearBrushTransientState() {
        activeBrushStroke = nil
        activeBrushLayerID = nil
        brushUndoStack.removeAll()
        brushStrokeLimitReachedMessage = nil
        isBrushPaintMode = false
    }

    // MARK: - AI マスク

    /// マスク生成ロジック（前処理・Vision モデル）の世代番号。生成結果の見えが変わる変更を
    /// 入れたら上げる。不一致のレイヤーには UI が再生成導線を出す（黙って作り直さない、§3.2）。
    static let currentVisionRevision = 1

    /// AI マスクのラスタを焼き込む長辺。`AIMaskReference.bakedLongEdge` として記録する（OQ-3）。
    private static let aiMaskBakedLongEdge = 1_024
    /// Vision へ渡すプレビューの最小長辺。`SubjectMaskGenerating` が要求する
    /// 「最小辺 512px 以上」を通常のアスペクト比で満たすための下限。
    private static let visionInputMinimumLongEdge: CGFloat = 1_024

    /// AI 被写体 / 人物マスクを追加し、選択状態にする。
    ///
    /// - Parameters:
    ///   - kind: 被写体マスクか人物マスクか。
    ///   - clickPoint: ベース空間の正規化座標（左上原点・y 下向き）。`nil` なら検出された
    ///     全インスタンスを使う。
    ///
    /// `.person` は「人物なし」を戻り値で判定できない（`SubjectMaskGenerating` の注記。
    /// 実測で confidence は常に 1.0）。したがって生成できたマスクは必ずレイヤーとして提示し、
    /// 不適切かどうかの判断は `removeMask(id:)` でユーザーに委ねる。
    /// - Returns: 生成に成功した新規レイヤーの ID。失敗・早期リターン時は `nil`。
    ///   `regenerateAIMask`/`refineAIMask` が「無関係な操作で `maskLayers.count` が
    ///   たまたま増えた」ことを成功と誤判定しないよう、カウント比較ではなく戻り値で成否を伝える
    ///   （レビュー指摘: AI 生成中に他種別マスクを追加されるとレイヤーを誤削除しうる）。
    @discardableResult
    func addAIMask(kind: AIMaskKind, clickPoint: NormalizedPoint? = nil) async -> UUID? {
        guard canEditMasks, !isGeneratingAIMask, let photo = currentPhoto else { return nil }

        isGeneratingAIMask = true
        aiMaskGenerationFailureMessage = nil
        defer { isGeneratingAIMask = false }

        // Vision 入力はベース空間（回転・トリミング前）で作る。表示空間を渡すと
        // マスクの正規化座標が `MaskImageGenerator` の基準とずれる（§1.5）。
        let params = parameters
        let target = max(
            PhotoImageViewModel.targetMaxPixelSize(for: displaySize),
            Self.visionInputMinimumLongEdge
        )
        guard let source = await engine.renderPreview(
            url: photo.fileURL,
            parameters: params,
            targetMaxPixelSize: target,
            rotation: 0,
            cropRect: nil,
            previewColorSpace: nil,
            useRAWParameterMapping: rawMappingActive,
            usesManualLensCorrection: shouldApplyManualLensCorrection(params),
            usesToneMaskedColorGrading: toneMaskedColorGradingActive,
            asShotWhiteBalance: toneMaskedColorGradingActive ? asShotWhiteBalance : nil,
            maskRasters: resolvedMaskRasters(for: params)
        ) else {
            aiMaskGenerationFailureMessage = String(localized: "develop.mask.ai.generationFailed")
            return nil
        }

        // Vision の正規化座標は左下原点・y 上向き。`NormalizedPoint` とは y が逆。
        let visionClickPoint = clickPoint.map { CGPoint(x: $0.x, y: 1 - $0.y) }
        guard let result = await maskGenerator.generateMask(
            for: source,
            kind: kind,
            clickPoint: visionClickPoint,
            targetLongEdge: Self.aiMaskBakedLongEdge
        ) else {
            aiMaskGenerationFailureMessage = switch kind {
            case .person: String(localized: "develop.mask.ai.noPersonFound")
            case .foregroundSubject: String(localized: "develop.mask.ai.noSubjectFound")
            }
            return nil
        }
        // 生成中に写真が切り替わっていたら、別写真のラスタを貼らない。
        guard currentPhoto?.id == photo.id else { return nil }

        // DevelopSettingsの確保はVision成功後に行う。Vision失敗・写真切替などの早期returnで
        // 中立な空行が永続的に残るのを防ぐため（updateDevelopParametersの「中立状態では
        // 行を作らない」という不変条件に反しないようにする。レビュー指摘）。
        guard let settings = content?.developSettingsForMaskRaster() else { return nil }

        let rasterID = UUID()
        let raster = MaskRaster(id: rasterID, pngData: result.pngData, longEdge: result.longEdge)
        settings.maskRasters.append(raster)

        let nameFormat = switch kind {
        case .person: String(localized: "develop.mask.ai.personName")
        case .foregroundSubject: String(localized: "develop.mask.ai.subjectName")
        }
        let layer = MaskLayer(
            id: UUID(),
            name: String(format: nameFormat, Int64(parameters.masks.count + 1)),
            source: .ai(AIMaskReference(
                rasterID: rasterID,
                kind: kind,
                instanceIndices: result.instanceIndices,
                visionRevision: Self.currentVisionRevision,
                bakedLongEdge: result.longEdge,
                bakedAt: .now
            )),
            adjustments: LocalAdjustments()
        )
        var updated = parameters
        updated.masks.append(layer)
        parameters = updated
        selectedMaskLayerID = layer.id
        return layer.id
    }

    /// このレイヤーが現行の Vision 世代と異なる世代で焼き込まれているか。UI の再生成導線の表示条件。
    func maskNeedsRegeneration(_ layer: MaskLayer) -> Bool {
        guard case .ai(let reference) = layer.source else { return false }
        if reference.visionRevision != Self.currentVisionRevision { return true }
        // visionRevisionは一致していても、参照先のMaskRasterが存在しない状態
        // （他写真のプリセットを誤って流用した等の防御的ケース）も再生成対象として扱う。
        // これが無いと、ユーザーはマスクが無効である理由に気づく手段が無い（レビュー指摘）。
        guard let settings = content?.currentDevelopSettings else { return false }
        return !settings.maskRasters.contains { $0.id == reference.rasterID }
    }

    /// AI マスクレイヤーを同じ種別で作り直す。ユーザーが明示的に呼んだときだけ実行し、
    /// `visionRevision` 不一致を検知して自動で作り直すことはしない（§3.2）。
    ///
    /// クリック位置は永続化していないため全インスタンス再検出になる。生成に失敗した場合は
    /// 元のレイヤーを残す（失敗して何も無くなる状態を作らない）。
    func regenerateAIMask(id: UUID) async {
        guard let layer = maskLayers.first(where: { $0.id == id }),
              case .ai(let reference) = layer.source else { return }
        // カウント比較ではなく戻り値の ID で成否判定する（レビュー指摘: 生成中に他種別の
        // マスクが追加されると `maskLayers.count` の増減だけでは誤判定する）。
        guard await addAIMask(kind: reference.kind) != nil else { return }
        removeMask(id: id)
    }

    // MARK: - Private

    /// AI マスクのラスタを MainActor 側で解決する。`MaskRaster` は `@Model` で `Sendable` でなく、
    /// engine の `Task.detached` へ直接渡せないため値（`CGImage`）に落として渡す契約になっている（§3.2.1）。
    /// 辞書に無い `rasterID` は描画側で全面 0 として扱われる。
    private func resolvedMaskRasters(for snapshot: DevelopParameters) -> [UUID: CGImage] {
        guard let settings = content?.currentDevelopSettings else { return [:] }
        var result: [UUID: CGImage] = [:]
        for layer in snapshot.masks where layer.isEnabled {
            guard case .ai(let reference) = layer.source else { continue }
            if let cached = maskRasterDecodeCache[reference.rasterID] {
                result[reference.rasterID] = cached
                continue
            }
            guard let raster = settings.maskRasters.first(where: { $0.id == reference.rasterID }),
                  let decoded = MaskRasterResolving.decodeCGImage(from: raster.pngData) else { continue }
            maskRasterDecodeCache[reference.rasterID] = decoded
            result[reference.rasterID] = decoded
        }
        return result
    }

    /// マスク可視化オーバーレイを現像プレビューとは独立のデバウンスで描き直す（§1.5.4）。
    private func scheduleMaskOverlayRender() {
        maskOverlayTask?.cancel()
        maskOverlayTask = nil
        guard maskEditMode, previewImage != nil, let photo = currentPhoto,
              parameters.masks.contains(where: { $0.isEnabled }) else {
            maskOverlayImage = nil
            return
        }
        let params = parameters
        let rot = rotation
        let crop = cropRect
        let mapping = rawMappingActive
        let rasters = resolvedMaskRasters(for: params)
        let target = PhotoImageViewModel.targetMaxPixelSize(for: displaySize)
        maskOverlayGeneration &+= 1
        let generation = maskOverlayGeneration
        maskOverlayTask = Task { [weak self] in
            try? await Task.sleep(for: Self.maskOverlayDebounce)
            guard !Task.isCancelled, let self else { return }
            let rendered = await self.engine.renderMaskOverlay(
                url: photo.fileURL,
                parameters: params,
                targetMaxPixelSize: target,
                rotation: rot,
                cropRect: crop,
                useRAWParameterMapping: mapping,
                maskRasters: rasters
            )
            guard !Task.isCancelled, generation == self.maskOverlayGeneration,
                  self.maskEditMode, self.currentPhoto?.id == photo.id else { return }
            self.maskOverlayTask = nil
            self.maskOverlayImage = rendered.map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        histogramTask?.cancel()
        guard let photo = currentPhoto else {
            _ = nextRenderGeneration()
            clearPreview()
            histogram = nil
            isRendering = false
            return
        }
        let params = parameters
        let rot = rotation
        let crop = cropRect
        // ドラッグ中は RAW 委譲を止めて標準チェーンで近似する。
        let mapping = rawMappingActive && !isRAWParameterDragging
        let manualLensCorrection = shouldApplyManualLensCorrection(params)
        let usesToneMaskedColorGrading = toneMaskedColorGradingActive
        let asShot = usesToneMaskedColorGrading ? asShotWhiteBalance : nil
        // RAW 再デコードを伴う描画は連打で溜めないよう長めのデバウンスにする。
        let debounce = mapping ? Self.rawMappingDebounce : renderDebounce
        let generation = nextRenderGeneration()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.render(
                photo: photo, parameters: params, rotation: rot, cropRect: crop,
                useRAWParameterMapping: mapping, usesManualLensCorrection: manualLensCorrection,
                usesToneMaskedColorGrading: usesToneMaskedColorGrading,
                asShotWhiteBalance: asShot,
                generation: generation
            )
        }
    }

    /// 現像レンダーを伴わない写真でも、選択時にヒストグラムを表示するため
    /// ベース画像（.neutral）から集計する。previewImage は変更しない。
    private func scheduleHistogramOnly(generation: Int) {
        guard let photo = currentPhoto else { return }
        let target = PhotoImageViewModel.targetMaxPixelSize(for: displaySize)
        let rot = rotation
        let crop = cropRect
        let colorSpace = previewColorSpace
        histogramTask?.cancel()
        histogramTask = Task { [weak self] in
            try? await Task.sleep(for: self?.renderDebounce ?? .zero)
            guard let self, !Task.isCancelled, generation == self.renderGeneration else { return }
            let base = await self.engine.renderPreview(
                url: photo.fileURL,
                parameters: .neutral,
                targetMaxPixelSize: target,
                rotation: rot,
                cropRect: crop,
                previewColorSpace: colorSpace,
                useRAWParameterMapping: false,
                usesManualLensCorrection: false,
                usesToneMaskedColorGrading: self.toneMaskedColorGradingActive,
                asShotWhiteBalance: nil,
                maskRasters: resolvedMaskRasters(for: .neutral)
            )
            guard generation == self.renderGeneration, let base else { return }
            let computed = await HistogramData.make(from: base)
            guard generation == self.renderGeneration else { return }
            self.histogram = computed
        }
    }

    private func render(
        photo: Photo,
        parameters params: DevelopParameters,
        rotation: Int,
        cropRect: CGRect?,
        useRAWParameterMapping: Bool,
        usesManualLensCorrection: Bool,
        usesToneMaskedColorGrading: Bool,
        asShotWhiteBalance: WhiteBalanceSample?,
        generation: Int
    ) async {
        // 調整も回転・トリミングも無ければエンジンを呼ばず、ベース画像表示へ戻す。
        // ただしマスク編集中は例外。`previewImage` を消すと `canEditMasks` が落ちてマスクを再追加できなくなる。
        guard !params.isNeutral || rotation != 0 || Self.isEffectiveCrop(cropRect) || maskEditMode else {
            if generation == renderGeneration {
                clearPreview()
                scheduleHistogramOnly(generation: generation)
                isRendering = false
            }
            return
        }

        isRendering = true
        let target = PhotoImageViewModel.targetMaxPixelSize(for: displaySize)
        let rendered = await engine.renderPreview(
            url: photo.fileURL,
            parameters: params,
            targetMaxPixelSize: target,
            rotation: rotation,
            cropRect: cropRect,
            previewColorSpace: previewColorSpace,
            useRAWParameterMapping: useRAWParameterMapping,
            usesManualLensCorrection: usesManualLensCorrection,
            usesToneMaskedColorGrading: usesToneMaskedColorGrading,
            asShotWhiteBalance: asShotWhiteBalance,
            maskRasters: resolvedMaskRasters(for: params)
        )
        // supersede されていたら後始末は最新世代に任せる。
        guard generation == renderGeneration else { return }

        isRendering = false
        guard let rendered else {
            // 一時的なレンダー失敗。誤ったパラメータのプレビューを残さず、ベース画像へ戻す。
            // マスク編集中は例外で直前のプレビューを残す。ここで捨てるとハンドルの座標基準
            // （§1.5.2）が失われ、編集セッションごと抜けてしまう。
            if !maskEditMode { previewImage = nil }
            histogram = nil
            return
        }
        previewImage = NSImage(cgImage: rendered, size: .zero)

        let computed = await HistogramData.make(from: rendered)
        guard generation == renderGeneration else { return }
        histogram = computed
    }

    /// 編集前プレビューを比較モードが必要になった時だけ遅延生成する。
    private func ensureBeforeImage() {
        guard beforeImage == nil, beforeImageTask == nil,
              let photo = currentPhoto else { return }

        beforeImageToken &+= 1
        let token = beforeImageToken
        let target = PhotoImageViewModel.targetMaxPixelSize(for: displaySize)
        let rot = rotation
        let crop = cropRect
        let colorSpace = previewColorSpace
        let usesToneMaskedColorGrading = toneMaskedColorGradingActive
        // After と同じ RAW デコード経路（CIRAWFilter）を通す。false にすると CIRAWFilter が
        // 既定でレンズ・色収差補正を掛けてしまい、mapping 経由の After（lensCorrectionEnabled
        // の中立値 = 補正なし）と見えが食い違う。
        let useRAWParameterMapping = rawMappingActive
        beforeImageTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.renderDebounce)
            guard !Task.isCancelled else { return }
            guard self.beforeImageToken == token,
                  self.currentPhoto?.id == photo.id else { return }
            let rendered = await self.engine.renderPreview(
                url: photo.fileURL,
                parameters: .neutral,
                targetMaxPixelSize: target,
                rotation: rot,
                cropRect: crop,
                previewColorSpace: colorSpace,
                useRAWParameterMapping: useRAWParameterMapping,
                usesManualLensCorrection: false,
                usesToneMaskedColorGrading: usesToneMaskedColorGrading,
                asShotWhiteBalance: nil,
                maskRasters: resolvedMaskRasters(for: .neutral)
            )
            guard self.beforeImageToken == token,
                  self.currentPhoto?.id == photo.id else { return }
            self.beforeImageTask = nil
            guard !Task.isCancelled else { return }
            guard let rendered else {
                self.isComparingSplit = false
                return
            }
            self.beforeImage = NSImage(cgImage: rendered, size: .zero)
        }
    }

    /// 写真・表示ジオメトリに依存する編集前プレビューを無効化する。
    private func invalidateBeforeImage() {
        beforeImageToken &+= 1
        beforeImageTask?.cancel()
        beforeImageTask = nil
        beforeImage = nil
    }

    /// 現像プレビューを消し、分割比較・マスク編集も終了する。
    /// マスク編集は表示基準に `previewImage` を使うため、プレビューが消えたら続行できない（§1.5.2）。
    private func clearPreview() {
        previewImage = nil
        isComparingSplit = false
        maskEditMode = false
    }

    /// パイプラインへ渡す手動レンズ補正の適用可否。schemaVersion ゲート + RAW のプロファイル補正が
    /// 有効なら手動はスキップ（二重補正防止。ドラッグ状態には依存しない）。
    private func shouldApplyManualLensCorrection(_ params: DevelopParameters) -> Bool {
        manualLensCorrectionActive && !(rawMappingActive && params.lensCorrectionEnabled)
    }

    private func applyAsShotWhiteBalance(_ sample: WhiteBalanceSample) {
        asShotWhiteBalance = sample
        if toneMaskedColorGradingActive, currentPhoto != nil, shouldRender {
            scheduleRender()
        }
    }

    /// 永続化時に DevelopSettings.setParameters が schemaVersion を現行世代へバンプするため、
    /// レコード由来のゲートフラグを再同期する。カラーグレーディング方式が切り替わったら再描画する。
    private func syncSchemaGatedFlags() {
        // レコードが中立で削除された場合は新規レコード相当（現行世代）として扱う。
        let settings = content?.currentDevelopSettings
        rawMappingActive = isRAW && (settings?.usesRAWParameterMapping ?? true)
        manualLensCorrectionActive = settings?.usesManualLensCorrection ?? true
        let wasToneMasked = toneMaskedColorGradingActive
        toneMaskedColorGradingActive = settings?.usesToneMaskedColorGrading ?? true
        if toneMaskedColorGradingActive != wasToneMasked, currentPhoto != nil, shouldRender {
            scheduleRender()
        }
    }

    /// 新しいレンダー要求の世代番号を発行する。
    private func nextRenderGeneration() -> Int {
        renderGeneration &+= 1
        return renderGeneration
    }

    private func schedulePersist() {
        persistTask?.cancel()
        guard let photoID = currentPhoto?.id else {
            pendingPersist = nil
            return
        }
        let params = parameters
        pendingPersist = (photoID, params)
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: self?.persistDebounce ?? .zero)
            guard !Task.isCancelled else { return }
            self?.content?.updateDevelopParameters(params)
            self?.syncSchemaGatedFlags()
            self?.pendingPersist = nil
        }
    }

    /// 写真から離れるタイミングで、その写真の孤児 `MaskRaster` を回収する（§3.2）。
    ///
    /// 対象は必ず「これから離れる写真」にする。表示しようとしている写真を対象にすると、
    /// 直前のレイヤー削除を 1 段 Undo で戻した直後の再訪でラスタが消えている恐れがある。
    /// `ContentViewModel.selectPhoto` が先に走るため `currentDevelopSettings` は既に次の写真を
    /// 指している。離れる写真はまだ差し替えていない `currentPhoto` から引く。
    /// デバウンス保存のフラッシュ後に呼ぶこと（未保存の blob を基準に到達判定しないため）。
    private func collectOrphanedMaskRastersForLeavingPhoto() {
        guard let photoID = currentPhoto?.id, let context = content?.modelContext else { return }
        MaskRasterGarbageCollector.collect(forPhotoID: photoID, in: context)
    }

    /// デバウンス待ちの保存を即時に書き込む。写真切り替えで取りこぼさないため `load` の冒頭で呼ぶ。
    private func flushPendingPersist() {
        persistTask?.cancel()
        guard let pending = pendingPersist else { return }
        pendingPersist = nil
        content?.persistDevelopParameters(pending.parameters, forPhotoID: pending.photoID)
    }
}
