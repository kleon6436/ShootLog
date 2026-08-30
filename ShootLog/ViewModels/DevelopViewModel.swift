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

    private let engine: any ImageDeveloping
    private let content: ContentViewModel?

    private var currentPhoto: Photo?
    private var displaySize: CGSize = .zero
    /// `EditInfo` 由来の回転角。プレビューにも焼き込む。
    private var rotation: Int = 0
    /// `EditInfo` 由来の正規化トリミング矩形（回転後の表示画像基準）。
    private var cropRect: CGRect?

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

    /// 連続操作をまとめる待ち時間。描画は体感優先で短く、保存は書き込み削減のため長めに取る。
    /// テストから短縮できるようにインスタンス値で持つ。
    private let renderDebounce: Duration
    private let persistDebounce: Duration
    /// この画素数を超える表示領域の変化があったときだけ再デコードする。
    private static let displaySizeChangeThreshold: CGFloat = 32

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
        renderTask?.cancel()
        persistTask?.cancel()
        if displaySize.width > 0, displaySize.height > 0 { self.displaySize = displaySize }
        currentPhoto = photo
        self.rotation = rotation
        self.cropRect = cropRect

        isApplyingLoadedState = true
        parameters = content?.currentDevelopSettings?.parameters ?? .neutral
        isApplyingLoadedState = false

        previewImage = nil
        histogram = nil
        isRendering = false
        isRAW = photo.map { engine.isRAW(url: $0.fileURL) } ?? false

        if let photo, shouldRender {
            let params = parameters
            let rot = rotation
            let crop = cropRect
            renderTask = Task { [weak self] in
                await self?.render(photo: photo, parameters: params, rotation: rot, cropRect: crop)
            }
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
        persistTask?.cancel()
        isApplyingLoadedState = true
        parameters = .neutral
        isApplyingLoadedState = false
        previewImage = nil
        histogram = nil
        isRendering = false
        content?.resetDevelop()
        if currentPhoto != nil, shouldRender {
            scheduleRender()
        }
    }

    // MARK: - Private

    private func scheduleRender() {
        renderTask?.cancel()
        guard let photo = currentPhoto else {
            previewImage = nil
            histogram = nil
            return
        }
        let params = parameters
        let rot = rotation
        let crop = cropRect
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: self?.renderDebounce ?? .zero)
            guard !Task.isCancelled else { return }
            await self?.render(photo: photo, parameters: params, rotation: rot, cropRect: crop)
        }
    }

    private func render(
        photo: Photo,
        parameters params: DevelopParameters,
        rotation: Int,
        cropRect: CGRect?
    ) async {
        // 調整も回転・トリミングも無ければエンジンを呼ばず、ベース画像表示へ戻す。
        guard !params.isNeutral || rotation != 0 || Self.isEffectiveCrop(cropRect) else {
            previewImage = nil
            histogram = nil
            isRendering = false
            return
        }

        isRendering = true
        let target = PhotoImageViewModel.targetMaxPixelSize(for: displaySize)
        let rendered = await engine.renderPreview(
            url: photo.fileURL,
            parameters: params,
            targetMaxPixelSize: target,
            rotation: rotation,
            cropRect: cropRect
        )
        guard !Task.isCancelled, isCurrent(photo: photo, parameters: params, rotation: rotation, cropRect: cropRect) else {
            return
        }

        isRendering = false
        guard let rendered else { return }
        previewImage = NSImage(cgImage: rendered, size: .zero)

        let computed = await HistogramData.make(from: rendered)
        guard isCurrent(photo: photo, parameters: params, rotation: rotation, cropRect: cropRect) else { return }
        histogram = computed
    }

    /// レンダー結果が今も最新の要求に対応しているか（写真・パラメータ・回転・トリミングとも一致）。
    private func isCurrent(
        photo: Photo,
        parameters params: DevelopParameters,
        rotation: Int,
        cropRect: CGRect?
    ) -> Bool {
        currentPhoto?.id == photo.id
            && parameters == params
            && self.rotation == rotation
            && self.cropRect == cropRect
    }

    private func schedulePersist() {
        persistTask?.cancel()
        let params = parameters
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: self?.persistDebounce ?? .zero)
            guard !Task.isCancelled else { return }
            self?.content?.updateDevelopParameters(params)
        }
    }
}
