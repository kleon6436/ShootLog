import AppKit
import SwiftUI

// 独自の左サイドバー開閉ボタンを使うため、AppKitが自動挿入するネイティブの
// サイドバートグル項目（折りたたみ時の >> を含む）を継続的に除去する。
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

        func applyRemoval() {
            bindToolbarObserverIfNeeded()
            removeNativeSidebarToggleButtons()
        }

        private func startBootstrapRemovalPasses() {
            bootstrapTask?.cancel()
            bootstrapTask = Task { @MainActor [weak self] in
                guard let self else { return }
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

            willAddObserver = NotificationCenter.default.addObserver(
                forName: NSToolbar.willAddItemNotification,
                object: toolbar,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.removeNativeSidebarToggleButtons()
                }
            }

            didRemoveObserver = NotificationCenter.default.addObserver(
                forName: NSToolbar.didRemoveItemNotification,
                object: toolbar,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.removeNativeSidebarToggleButtons()
                }
            }

            didChangeVisibleItemsObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("NSToolbarDidChangeVisibleItemsNotification"),
                object: toolbar,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.removeNativeSidebarToggleButtons()
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
                if rawID.contains("sidebar") && actionName.contains("sidebar") {
                    return true
                }
            }

            return false
        }
    }
}
