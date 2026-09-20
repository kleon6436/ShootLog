import SwiftUI

// 全表示モード（sidebar/fullscreen/slideshow）の標準ツールバーで共有する部品群。
// ForEachをツールバー式に直接書くと型検査がタイムアウトするため独立Viewへ切り出している

// ツールバー内の表示モード切替（セグメント）。モード一覧は呼び出し元のVM経由で渡す
// （ViewModeRegistry.sharedへのアクセスはVM層に閉じ、View層からは直接参照しない）
struct ModeTogglePicker: View {
    @Binding var currentModeID: String
    let modes: [any ViewModeProtocol]

    var body: some View {
        Picker("toolbar.viewMode", selection: $currentModeID) {
            ForEach(modes, id: \.id) { mode in
                Image(systemName: mode.symbolName)
                    .accessibilityLabel(Text(mode.displayName))
                    .tag(mode.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("toolbar.viewMode")
    }
}

// 外部アプリで開くメニュー。アプリ一覧は呼び出し元のVM経由で渡す
// （ExternalAppRegistry.sharedへのアクセスはVM層に閉じ、View層からは直接参照しない）
struct ExternalAppMenu: View {
    let apps: [any ExternalAppProtocol]
    let onSelect: (any ExternalAppProtocol) -> Void

    var body: some View {
        Menu {
            ForEach(apps, id: \.id) { adapter in
                Button { onSelect(adapter) } label: {
                    Label(adapter.displayName, systemImage: adapter.symbolName)
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .help("toolbar.externalApp.help")
        .accessibilityLabel("toolbar.externalApp.help")
    }
}

// お気に入りのみ表示の絞り込みトグル。3モード共通のボタン本体だけを共有し、
// ToolbarItemGroupへの配置は各モードのView側に残す（sidebarモードのみ隣接アイテムが異なるため）
struct FavoritesOnlyToggleButton: View {
    @Binding var showFavoritesOnly: Bool
    let isDisabled: Bool

    var body: some View {
        Button { showFavoritesOnly.toggle() } label: {
            // ONのときだけ黄色にする。写真.app・Finderのタグと同じ「お気に入り＝黄色」の意味付けで、
            // 絞り込みが効いていることを記号の形（star/star.fill）と色の二重で伝える
            Image(systemName: showFavoritesOnly ? "star.fill" : "star")
                .foregroundStyle(showFavoritesOnly ? Color.yellow : Color.primary)
        }
        .help("toolbar.favoritesOnly")
        .accessibilityLabel("toolbar.favoritesOnly")
        .disabled(isDisabled)
    }
}

// AI検出カテゴリによる複数選択フィルタ。メニューの表示・選択状態はOS標準のUIに委ねる
struct AICategoryFilterMenu: View {
    @Binding var selectedCategories: Set<AISubjectCategory>
    let availableCategories: [AISubjectCategory]
    let isDisabled: Bool

    var body: some View {
        Menu {
            ForEach(availableCategories, id: \.self) { category in
                Toggle(isOn: binding(for: category)) {
                    Text(category.displayName)
                }
            }
            if !selectedCategories.isEmpty {
                Divider()
                Button("sidebar.aiCategoryFilter.clear") {
                    selectedCategories.removeAll()
                }
            }
        } label: {
            // 絞り込み中はメニューを開かなくても対象が分かるよう、記号に加えて選択内容を短く添える
            if selectedCategories.isEmpty {
                Image(systemName: "tag")
            } else {
                Label {
                    Text(selectionSummary)
                } icon: {
                    Image(systemName: "tag.fill")
                }
            }
        }
        .help("toolbar.aiCategoryFilter.help")
        .accessibilityLabel(accessibilityLabelText)
        .disabled(isDisabled || (availableCategories.isEmpty && selectedCategories.isEmpty))
    }

    // 選択中カテゴリを availableCategories の安定した宣言順に並べ直す。
    // Set の列挙順は不定なので、ラベルの文言が再描画のたびに入れ替わらないようにする
    private var orderedSelection: [AISubjectCategory] {
        let ordered = availableCategories.filter { selectedCategories.contains($0) }
        guard ordered.isEmpty else { return ordered }
        // 絞り込み中にフォルダを切り替えた直後など、availableCategories に含まれない選択が残る場合の保険
        return AISubjectCategory.allCases.filter { selectedCategories.contains($0) }
    }

    // 「風景」「風景 · 2」のような短い要約。ツールバーの幅を圧迫しないよう先頭1件＋件数に留める
    private var selectionSummary: String {
        guard let first = orderedSelection.first else { return "" }
        let name = String(localized: first.displayName)
        guard selectedCategories.count > 1 else { return name }
        return String(localized: "toolbar.aiCategoryFilter.summary \(name) \(selectedCategories.count)")
    }

    // VoiceOver では記号が読まれないため、絞り込み中は何で絞っているかまで読み上げる
    private var accessibilityLabelText: Text {
        if selectedCategories.isEmpty {
            return Text("toolbar.aiCategoryFilter.help")
        }
        return Text("a11y.toolbar.aiCategoryFilter \(selectionSummary)")
    }

    private func binding(for category: AISubjectCategory) -> Binding<Bool> {
        Binding(
            get: { selectedCategories.contains(category) },
            set: { isOn in
                if isOn {
                    selectedCategories.insert(category)
                } else {
                    selectedCategories.remove(category)
                }
            }
        )
    }
}

// 3モード共通のツールバー末尾グループ（分析・外部アプリ・設定）。
// fullscreen/slideshowモードでは同じグループの先頭に「フォルダを開く」が並ぶため
// openFolderを任意で受け取る。sidebarモードは同ボタンを.navigation配置に持つのでnilで呼ぶ
struct ViewerToolbarTrailingGroup: ToolbarContent {
    let isPhotosEmpty: Bool
    let hasSelectedPhoto: Bool
    let externalApps: [any ExternalAppProtocol]
    var openFolder: (() -> Void)?
    let openAnalysis: () -> Void
    let openInExternalApp: (any ExternalAppProtocol) -> Void
    let openSettings: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let openFolder {
                Button { openFolder() } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("toolbar.openFolder.help")
                .accessibilityLabel("common.openFolder")
            }

            Button { openAnalysis() } label: {
                Image(systemName: "chart.bar")
            }
            .help("toolbar.analysis.help")
            .accessibilityLabel("toolbar.analysis")
            .keyboardShortcut("i", modifiers: .command)
            .disabled(isPhotosEmpty)

            ExternalAppMenu(apps: externalApps, onSelect: openInExternalApp)
                .disabled(!hasSelectedPhoto)

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .help("toolbar.settings")
            .accessibilityLabel("toolbar.settings")
        }
    }
}

// 黒背景HUD上の回転ボタン。fullscreen/slideshowモードでスタイル・ラベルを揃える。
// slideshowモードのみRキーのショートカットを持つためshortcutを任意で受け取る
struct RotateButton: View {
    let action: () -> Void
    var shortcut: KeyEquivalent?

    init(shortcut: KeyEquivalent? = nil, action: @escaping () -> Void) {
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "rotate.right")
                .foregroundStyle(Color.onViewerCanvasSecondary)
                .frame(width: 44, height: 44)
                .glassOrMaterialCircle()
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
        .help("toolbar.rotate.help")
        .accessibilityLabel("a11y.toolbar.rotate")
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0, modifiers: []) })
    }
}

// 黒背景HUD上のAI超解像書き出しボタン。RotateButtonと同じスタイル・配置規則に揃える
struct UpscaleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "wand.and.sparkles")
                .foregroundStyle(Color.onViewerCanvasSecondary)
                .frame(width: 44, height: 44)
                .glassOrMaterialCircle()
        }
        .buttonStyle(HUDButtonStyle(font: HUDTypography.icon))
        .help("toolbar.upscale.help")
        .accessibilityLabel("a11y.toolbar.upscale")
    }
}

// 「3 / 12」形式のインデックスカウンター。外側のpaddingは呼び出し側で付与する。
// fullscreen/slideshowの黒背景HUDと、サイドバーモードのビューア右上で共有する
struct CounterBadge: View {
    let text: String
    // サイドバーモードのビューアは通常のウィンドウ内なので Dynamic Type に乗る .caption を渡す。
    // 黒背景HUD（fullscreen/slideshow）は固定サイズの HUDTypography を使うため既定値のままにする
    var font: Font = HUDTypography.label

    var body: some View {
        Text(text)
            .font(font)
            // 写真送りで桁が変わっても badge の幅が揺れないようにする
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassOrMaterialCapsule()
    }
}
