import SwiftUI

/// 右インスペクタの中身。EXIF 情報タブと現像編集タブを切り替える。
struct InspectorTabContainer: View {
    @Bindable var sidebarViewModel: SidebarViewModel
    let photo: Photo?
    let onToggleTag: (SuccessTagCategory) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("inspector.tab", selection: $sidebarViewModel.inspectorTab) {
                Text("inspector.tab.exif").tag(SidebarViewModel.InspectorTab.exif)
                Text("inspector.tab.develop").tag(SidebarViewModel.InspectorTab.develop)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Spacing.medium)

            Divider()

            switch sidebarViewModel.inspectorTab {
            case .exif:
                EXIFPanelView(photo: photo, onToggleTag: onToggleTag)
            case .develop:
                if photo != nil {
                    DevelopPanelView(developViewModel: sidebarViewModel.developViewModel)
                } else {
                    ContentUnavailableView(
                        "develop.empty.noSelection",
                        systemImage: "slider.horizontal.3"
                    )
                }
            }
        }
    }
}
