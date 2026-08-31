import AppKit
import Foundation

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
        }
    }

    /// 現像適用済みのプレビュー。`nil` の間はベース画像（`PhotoImageViewModel`）を表示する。
    private(set) var previewImage: NSImage?
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
    var isShowingBefore = false
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
    private let content: ContentViewModel?

    private var currentPhoto: Photo?
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
    /// この画素数を超える表示領域の変化があったときだけ再デコードする。
    private static let displaySizeChangeThreshold: CGFloat = 32
    /// RAW の露出・WB を `CIRAWFilter` で再デコードする描画のデバウンス。標準チェーンより長く取る。
    private static let rawMappingDebounce: Duration = .milliseconds(180)

    init(
        engine: any ImageDeveloping = ImageDevelopmentEngine.shared,
        content: ContentViewModel?,
        renderDebounce: Duration = .milliseconds(60),
        persistDebounce: Duration = .milliseconds(500)
    ) {
        self.engine = engine
        self.content = content
        self.renderDebounce = renderDebounce
        self.persistDebounce = persistDebounce
        self.showsClippingWarnings = UserDefaults.standard.object(forKey: AppSettingsKeys.developClippingWarnings) as? Bool
            ?? AppSettingsKeys.developClippingWarningsDefault
    }

    // MARK: - ライフサイクル

    /// 写真切り替え時に呼ぶ。保存済み調整値をロードし、調整または回転・トリミングがあれば即プレビューする。
    func load(photo: Photo?, displaySize: CGSize, rotation: Int = 0, cropRect: CGRect? = nil) {
        // 切り替え前の写真のデバウンス保存を取りこぼさないよう、先にフラッシュする。
        flushPendingPersist()
        renderTask?.cancel()
        histogramTask?.cancel()
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
        previewImage = nil
        histogram = nil
        isRendering = false
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
    func setRAWParameterDragging(_ dragging: Bool) {
        guard rawMappingActive, dragging != isRAWParameterDragging else { return }
        isRAWParameterDragging = dragging
        // ドラッグ終了時のみ再レンダー（開始時は didSet 側の描画に任せる）。
        if !dragging, currentPhoto != nil, shouldRender {
            scheduleRender()
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
                asShotWhiteBalance: nil
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

    /// 回転・トリミングの変更を受けて再レンダーする。調整も幾何変換も無くなればプレビューを解除する。
    func updateEditGeometry(rotation: Int, cropRect: CGRect?) {
        guard rotation != self.rotation || cropRect != self.cropRect else { return }
        self.rotation = rotation
        self.cropRect = cropRect
        guard currentPhoto != nil else { return }
        if shouldRender {
            scheduleRender()
        } else {
            renderTask?.cancel()
            histogramTask?.cancel()
            _ = nextRenderGeneration()
            previewImage = nil
            scheduleHistogramOnly(generation: renderGeneration)
            isRendering = false
        }
    }

    /// ビューアが載っているディスプレイの色空間を伝える。P3 ディスプレイなら P3 を渡すと
    /// プレビューが P3 書き出しの見えと一致する。`nil` で sRGB。変化があれば再描画する。
    func setPreviewColorSpace(_ colorSpace: CGColorSpace?) {
        guard !Self.sameColorSpace(colorSpace, previewColorSpace) else { return }
        previewColorSpace = colorSpace
        if currentPhoto != nil, shouldRender {
            scheduleRender()
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
        if changed, currentPhoto != nil, shouldRender {
            scheduleRender()
        } else if changed, currentPhoto != nil {
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
        _ = nextRenderGeneration()
        isApplyingLoadedState = true
        parameters = .neutral
        isApplyingLoadedState = false
        previewImage = nil
        histogram = nil
        isRendering = false
        content?.resetDevelop()
        // reset で旧レコードは削除され、次の保存は schemaVersion 5（RAW は露出・WB 委譲も有効）。
        manualLensCorrectionActive = true
        rawMappingActive = isRAW
        toneMaskedColorGradingActive = true
        undoParameters = nil
        canUndo = false
        if currentPhoto != nil, shouldRender {
            scheduleRender()
        } else if currentPhoto != nil {
            scheduleHistogramOnly(generation: renderGeneration)
        }
    }

    /// セクション単位で調整を中立へ戻す。didSet 経由でプレビュー再描画・保存が予約される。
    func resetSection(_ section: DevelopSection) {
        guard parameters.isModified(in: section) else { return }
        parameters.reset(section)
    }

    // MARK: - プリセット / コピー & ペースト

    /// 現在の調整値をプリセットとして保存する。
    func saveCurrentAsPreset(name: String) {
        content?.saveDevelopPreset(name: name, from: parameters)
    }

    func deletePreset(_ preset: DevelopPreset) {
        content?.deleteDevelopPreset(preset)
    }

    func renamePreset(_ preset: DevelopPreset, to name: String) {
        content?.renameDevelopPreset(preset, to: name)
    }

    /// プリセットの調整値を適用する。直前の状態は 1 段だけ戻せる。
    /// - Parameter relative: `true` なら現在の調整値へプリセットを差分として重ねる（露出違いの
    ///   複数カットへ同じスタイルを崩さず足せる）。`false`（既定）なら丸ごと置き換える。
    func applyPreset(_ preset: DevelopPreset, relative: Bool = false) {
        let target = relative ? parameters.applying(delta: preset.parameters) : preset.parameters
        applyReplacingParameters(target)
    }

    /// 現在の調整値をクリップボードへコピーする。
    func copyAdjustments() {
        Self.clipboard = parameters
        canPaste = true
    }

    /// クリップボードの調整値を適用する。直前の状態は 1 段だけ戻せる。
    func pasteAdjustments() {
        guard let clip = Self.clipboard else { return }
        applyReplacingParameters(clip)
    }

    /// プリセット適用・ペーストを 1 段だけ取り消す。
    func undoLastApply() {
        guard let target = undoParameters else { return }
        undoParameters = nil
        canUndo = false
        parameters = target
    }

    /// `parameters` を丸ごと差し替える。didSet でプレビュー再描画・永続化が予約される。
    private func applyReplacingParameters(_ new: DevelopParameters) {
        guard new != parameters else { return }
        undoParameters = parameters
        canUndo = true
        parameters = new
    }

    // MARK: - Private

    private func scheduleRender() {
        renderTask?.cancel()
        histogramTask?.cancel()
        guard let photo = currentPhoto else {
            _ = nextRenderGeneration()
            previewImage = nil
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
                asShotWhiteBalance: nil
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
        guard !params.isNeutral || rotation != 0 || Self.isEffectiveCrop(cropRect) else {
            if generation == renderGeneration {
                previewImage = nil
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
            asShotWhiteBalance: asShotWhiteBalance
        )
        // supersede されていたら後始末は最新世代に任せる。
        guard generation == renderGeneration else { return }

        isRendering = false
        guard let rendered else {
            // 一時的なレンダー失敗。誤ったパラメータのプレビューを残さず、ベース画像へ戻す。
            previewImage = nil
            histogram = nil
            return
        }
        previewImage = NSImage(cgImage: rendered, size: .zero)

        let computed = await HistogramData.make(from: rendered)
        guard generation == renderGeneration else { return }
        histogram = computed
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

    /// デバウンス待ちの保存を即時に書き込む。写真切り替えで取りこぼさないため `load` の冒頭で呼ぶ。
    private func flushPendingPersist() {
        persistTask?.cancel()
        guard let pending = pendingPersist else { return }
        pendingPersist = nil
        content?.persistDevelopParameters(pending.parameters, forPhotoID: pending.photoID)
    }
}
