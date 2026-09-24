import AppKit
import Foundation
import ImageIO
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
    // DevelopViewModelAIMask.swift から更新するため setter も internal
    var isGeneratingAIMask = false
    /// 直近の AI マスク生成が失敗した理由。成功・写真切り替え・次の生成開始で消える。
    // DevelopViewModelAIMask.swift から更新するため setter も internal
    var aiMaskGenerationFailureMessage: String?
    /// ブラシの半径。ベース空間の正規化座標（extent 短辺に対する比率）。
    var brushRadius: Double = DevelopViewModel.defaultBrushRadius
    /// ブラシの硬さ（0...100）。0 でソフト、100 でシャープ。
    var brushHardness: Double = 50
    /// ブラシの不透明度（0...100）。
    var brushOpacity: Double = 100
    /// true の間、次に描くストロークは消しゴム（減算）になる。
    var isBrushEraserMode = false
    /// ストローク上限に達して追加できなかったときのインライン通知。
    // DevelopViewModelBrush.swift から更新するため setter も internal
    var brushStrokeLimitReachedMessage: String?
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

    /// マスクセクションを一度でも開き、ベースプレビューを用意したか。
    ///
    /// これが `true` の間は `render()` のneutral最適化（`previewImage` を `nil` に戻す）を
    /// スキップし、無調整に戻っても `previewImage` を維持し続ける。`maskEditMode`
    /// （オーバーレイ表示トグル）はユーザーが明示的にオンにするまで `false` のままで、
    /// マスク追加・削除自体はこのトグルと無関係に行えるため、`maskEditMode` だけでは
    /// 「マスクを削除して無調整に戻ったら `canEditMasks` が `false` に戻り再追加できなくなる」
    /// バグ（実機報告）を防げない。写真を切り替えるまで維持する。
    private var didPrepareMaskEditingPreview = false

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
            self.didPrepareMaskEditingPreview = true
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

    // DevelopViewModelAIMask.swift / DevelopViewModelPresets.swift から参照するため internal
    let engine: any ImageDeveloping
    let maskGenerator: any SubjectMaskGenerating
    let content: ContentViewModel?

    /// `MaskRaster.pngData` のデコード結果。スライダー操作のたびに PNG を展開し直さないため、
    /// `rasterID` をキーに保持する。ラスタの中身は生成時に確定し以後変わらない（再生成は
    /// 新しい `rasterID` を発行する）ので、ID 一致だけで再利用してよい。写真切り替えで捨てる。
    private var maskRasterDecodeCache: [UUID: CGImage] = [:]

    /// ドラッグ中のストローク。確定（`endBrushStroke`）までレイヤーへは書き込まない。
    // DevelopViewModelBrush.swift / DevelopViewModelMasks.swift から更新するため internal
    var activeBrushStroke: BrushStroke?
    var activeBrushLayerID: UUID?
    /// ブラシ専用の Undo 履歴。永続化せずメモリ内だけで持つ（写真切り替えで破棄）。
    var brushUndoStack: [(layerID: UUID, previousBrushEdits: [BrushStroke])] = []

    // DevelopViewModelAIMask.swift から参照するため private(set)
    private(set) var currentPhoto: Photo?
    /// 写真切り替え検知用（`.task(id:)` 等、View 側は `currentPhoto` 自体に触れない）。
    var currentPhotoID: UUID? { currentPhoto?.id }
    // DevelopViewModelAIMask.swift から参照するため private(set)
    private(set) var displaySize: CGSize = .zero
    /// `EditInfo` 由来の回転角。プレビューにも焼き込む。
    private var rotation: Int = 0
    /// `EditInfo` 由来の正規化トリミング矩形（回転後の表示画像基準）。
    private var cropRect: CGRect?
    /// RAW の露出・WB を `CIRAWFilter` 側で解釈するか（`DevelopSettings.schemaVersion` >= 2 の RAW）。
    // DevelopViewModelAIMask.swift から参照するため private(set)
    private(set) var rawMappingActive = false
    /// 手動レンズ補正を解釈するか（`DevelopSettings.schemaVersion` >= 2）。
    private var manualLensCorrectionActive = false
    /// カラーグレーディングへトーン域マスク方式を適用するか（`DevelopSettings.schemaVersion` >= 5）。
    // DevelopViewModelAIMask.swift から参照するため private(set)
    private(set) var toneMaskedColorGradingActive = false
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
        didPrepareMaskEditingPreview = false
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

    // MARK: - コピー & ペースト / Undo

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
    // DevelopViewModelPresets.swift から参照するため internal
    func applyReplacingParameters(_ new: DevelopParameters, duplicatingAIMaskRastersFrom index: Int? = nil) {
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

    // MARK: - Private

    /// AI マスクのラスタを MainActor 側で解決する。`MaskRaster` は `@Model` で `Sendable` でなく、
    /// engine の `Task.detached` へ直接渡せないため値（`CGImage`）に落として渡す契約になっている（§3.2.1）。
    /// 辞書に無い `rasterID` は描画側で全面 0 として扱われる。
    // DevelopViewModelAIMask.swift から参照するため internal
    func resolvedMaskRasters(for snapshot: DevelopParameters) -> [UUID: CGImage] {
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
        // ただしマスクセクションを一度でも開いていれば例外。`previewImage` を消すと
        // `canEditMasks` が落ち、マスクを削除して無調整に戻ったときに再追加できなくなる
        // （`maskEditMode` はオーバーレイ表示トグルでマスク追加・削除とは独立に false でいられるため、
        // それだけでは条件として不十分）。
        guard !params.isNeutral || rotation != 0 || Self.isEffectiveCrop(cropRect)
            || maskEditMode || didPrepareMaskEditingPreview else {
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
            // マスク編集中・マスクセクションを開いた後は例外で直前のプレビューを残す。
            // ここで捨てるとハンドルの座標基準（§1.5.2）や `canEditMasks` が失われてしまう。
            if !maskEditMode, !didPrepareMaskEditingPreview { previewImage = nil }
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
    // DevelopViewModelAIMask.swift から参照するため internal
    func shouldApplyManualLensCorrection(_ params: DevelopParameters) -> Bool {
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
