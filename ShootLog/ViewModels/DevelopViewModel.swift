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

    /// リセット可能か（何らかの調整が入っている）。
    var canReset: Bool { !parameters.isNeutral }

    /// RAW かつ `CIRAWFilter` 委譲が有効か（レンズ補正トグルなど RAW 固有 UI の表示条件）。
    var canDelegateToRAWFilter: Bool { rawMappingActive }

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
    /// 露出・色温度・色かぶりのスライダーをドラッグ中か。ドラッグ中は RAW 再デコードを避け、
    /// 標準チェーンで近似プレビューを出す。離した時点で `CIRAWFilter` 経路へ切り替えて描き直す。
    private var isRAWParameterDragging = false

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
    }

    // MARK: - ライフサイクル

    /// 写真切り替え時に呼ぶ。保存済み調整値をロードし、調整または回転・トリミングがあれば即プレビューする。
    func load(photo: Photo?, displaySize: CGSize, rotation: Int = 0, cropRect: CGRect? = nil) {
        // 切り替え前の写真のデバウンス保存を取りこぼさないよう、先にフラッシュする。
        flushPendingPersist()
        renderTask?.cancel()
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
        // version 1 の既存 RAW レコードは標準チェーンのまま（色が変わらないように）。
        // レコードが無い新規は version 2 相当として委譲する。
        rawMappingActive = isRAW && (content?.currentDevelopSettings?.usesRAWParameterMapping ?? true)

        if let photo, shouldRender {
            let params = parameters
            let rot = rotation
            let crop = cropRect
            let mapping = rawMappingActive
            let generation = renderGeneration
            renderTask = Task { [weak self] in
                await self?.render(
                    photo: photo, parameters: params, rotation: rot, cropRect: crop,
                    useRAWParameterMapping: mapping, generation: generation
                )
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
            _ = nextRenderGeneration()
            previewImage = nil
            histogram = nil
            isRendering = false
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
        }
    }

    /// 現像調整を全て取り消す。回転・トリミング（`ContentViewModel.resetEdits`）には影響しない。
    /// 回転・トリミングが残っていれば、それだけを焼き込んだプレビューを出し直す。
    func reset() {
        renderTask?.cancel()
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
        undoParameters = nil
        canUndo = false
        if currentPhoto != nil, shouldRender {
            scheduleRender()
        }
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
    func applyPreset(_ preset: DevelopPreset) {
        applyReplacingParameters(preset.parameters)
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
        // RAW 再デコードを伴う描画は連打で溜めないよう長めのデバウンスにする。
        let debounce = mapping ? Self.rawMappingDebounce : renderDebounce
        let generation = nextRenderGeneration()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.render(
                photo: photo, parameters: params, rotation: rot, cropRect: crop,
                useRAWParameterMapping: mapping, generation: generation
            )
        }
    }

    private func render(
        photo: Photo,
        parameters params: DevelopParameters,
        rotation: Int,
        cropRect: CGRect?,
        useRAWParameterMapping: Bool,
        generation: Int
    ) async {
        // 調整も回転・トリミングも無ければエンジンを呼ばず、ベース画像表示へ戻す。
        guard !params.isNeutral || rotation != 0 || Self.isEffectiveCrop(cropRect) else {
            if generation == renderGeneration {
                previewImage = nil
                histogram = nil
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
            useRAWParameterMapping: useRAWParameterMapping
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
