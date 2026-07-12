import AppKit
import SwiftUI

// SwiftUIの.toolbar(removing: .sidebarToggle)だけでは、macOS 26でAppKitが
// ウィンドウのNSToolbarへ自動挿入するネイティブのサイドバートグルボタンを
// 抑止できないケースがあるため、AppKit階層で継続的に除去する。
struct NativeSidebarToggleRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> GuardView {
        GuardView()
    }

    func updateNSView(_ nsView: GuardView, context: Context) {
        nsView.applyRemoval()
    }

    @MainActor
    final class GuardView: NSView {
        private weak var observedToolbar: NSToolbar?
        private var willAddObserver: NSObjectProtocol?
        private var didRemoveObserver: NSObjectProtocol?
        private var didChangeVisibleItemsObserver: NSObjectProtocol?
        private var bootstrapTask: Task<Void, Never>?

        deinit {
            bootstrapTask?.cancel()
            MainActor.assumeIsolated {
                removeObservers()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            guard window != nil else {
                bootstrapTask?.cancel()
                removeObservers()
                observedToolbar = nil
                return
            }

            bindToolbarObserverIfNeeded()
            applyRemoval()
            window?.toolbar?.validateVisibleItems()
            startBootstrapRemovalPasses()
        }

        override func layout() {
            super.layout()
        }

        func applyRemoval() {
            bindToolbarObserverIfNeeded()
            removeNativeSidebarToggleButtons()
        }

        private func startBootstrapRemovalPasses() {
            bootstrapTask?.cancel()
            bootstrapTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // ウィンドウ接続直後はNSToolbarの自動挿入が遅れて走ることがあるため、
                // 数フレーム分だけ再試行して取りこぼしを防ぐ。
                for _ in 0..<8 {
                    if Task.isCancelled { return }
                    self.applyRemoval()
                    await Task.yield()
                }
            }
        }

        private func bindToolbarObserverIfNeeded() {
            guard let toolbar = window?.toolbar else {
                removeObservers()
                observedToolbar = nil
                return
            }
            guard observedToolbar !== toolbar else {
                removeNativeSidebarToggleButtons()
                return
            }

            removeObservers()
            observedToolbar = toolbar

            // 項目追加時に再除去
            willAddObserver = NotificationCenter.default.addObserver(
                forName: NSToolbar.willAddItemNotification,
                object: toolbar,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self.removeNativeSidebarToggleButtons()
                    }
                } else {
                    Task { @MainActor in
                        self.removeNativeSidebarToggleButtons()
                    }
                }
            }

            // 項目削除後にも再評価
            didRemoveObserver = NotificationCenter.default.addObserver(
                forName: NSToolbar.didRemoveItemNotification,
                object: toolbar,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self.removeNativeSidebarToggleButtons()
                    }
                } else {
                    Task { @MainActor in
                        self.removeNativeSidebarToggleButtons()
                    }
                }
            }

            // 追加/削除を伴わない表示状態の変化（非表示→再表示）にも追従
            didChangeVisibleItemsObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("NSToolbarDidChangeVisibleItemsNotification"),
                object: toolbar,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self.removeNativeSidebarToggleButtons()
                    }
                } else {
                    Task { @MainActor in
                        self.removeNativeSidebarToggleButtons()
                    }
                }
            }
        }

        private func removeObservers() {
            if let willAddObserver {
                NotificationCenter.default.removeObserver(willAddObserver)
                self.willAddObserver = nil
            }
            if let didRemoveObserver {
                NotificationCenter.default.removeObserver(didRemoveObserver)
                self.didRemoveObserver = nil
            }
            if let didChangeVisibleItemsObserver {
                NotificationCenter.default.removeObserver(didChangeVisibleItemsObserver)
                self.didChangeVisibleItemsObserver = nil
            }
        }

        private func removeNativeSidebarToggleButtons() {
            guard let toolbar = observedToolbar ?? window?.toolbar else { return }

            let indices = toolbar.items.enumerated().compactMap { index, item in
                shouldRemove(item) ? index : nil
            }

            for index in indices.reversed() {
                toolbar.removeItem(at: index)
            }
        }

        private func shouldRemove(_ item: NSToolbarItem) -> Bool {
            if item.itemIdentifier == .toggleSidebar {
                return true
            }

            let rawID = item.itemIdentifier.rawValue.lowercased()
            if rawID.contains("togglesidebar") {
                return true
            }

            if let action = item.action {
                let actionName = NSStringFromSelector(action).lowercased()
                if actionName.contains("togglesidebar") {
                    return true
                }
                // OS差分で識別子が変わっても、実際にサイドバー切替アクションを持つ項目のみ除去する
                if rawID.contains("sidebar") && actionName.contains("sidebar") {
                    return true
                }
            }

            return false
        }
    }
}