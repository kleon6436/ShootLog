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

    /// 写真切り替え時に呼ぶ。保存済み調整値をロードし、非中立なら即プレビューする。
    func load(photo: Photo?, displaySize: CGSize) {
        renderTask?.cancel()
        persistTask?.cancel()
        if displaySize.width > 0, displaySize.height > 0 { self.displaySize = displaySize }
        currentPhoto = photo

        isApplyingLoadedState = true
        parameters = content?.currentDevelopSettings?.parameters ?? .neutral
        isApplyingLoadedState = false

        previewImage = nil
        histogram = nil
        isRendering = false
        isRAW = photo.map { engine.isRAW(url: $0.fileURL) } ?? false

        if let photo, !parameters.isNeutral {
            let params = parameters
            renderTask = Task { [weak self] in
                await self?.render(photo: photo, parameters: params)
            }
        }
    }

    /// ビューア領域のサイズ変化を伝える。大きく変わったときだけ再描画する。
    func updateDisplaySize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = abs(size.width - displaySize.width) > Self.displaySizeChangeThreshold
            || abs(size.height - displaySize.height) > Self.displaySizeChangeThreshold
        displaySize = size
        if changed, currentPhoto != nil, !parameters.isNeutral {
            scheduleRender()
        }
    }

    /// 現像調整を全て取り消す。回転・トリミング（`ContentViewModel.resetEdits`）には影響しない。
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
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: self?.renderDebounce ?? .zero)
            guard !Task.isCancelled else { return }
            await self?.render(photo: photo, parameters: params)
        }
    }

    private func render(photo: Photo, parameters params: DevelopParameters) async {
        // 中立へ戻ったらエンジンを呼ばず、ベース画像表示へ戻す。
        guard !params.isNeutral else {
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
            targetMaxPixelSize: target
        )
        guard !Task.isCancelled, isCurrent(photo: photo, parameters: params) else { return }

        isRendering = false
        guard let rendered else { return }
        previewImage = NSImage(cgImage: rendered, size: .zero)

        let computed = await HistogramData.make(from: rendered)
        guard isCurrent(photo: photo, parameters: params) else { return }
        histogram = computed
    }

    /// レンダー結果が今も最新の要求に対応しているか（写真・パラメータとも一致）。
    private func isCurrent(photo: Photo, parameters params: DevelopParameters) -> Bool {
        currentPhoto?.id == photo.id && parameters == params
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
