import Foundation
import Testing

@testable import ShootLog

@MainActor
struct SidebarViewModelDevelopTests {

    private func clearStoredTab() {
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.inspectorTab)
    }

    @Test func defaultsToExifTab() {
        clearStoredTab()
        let vm = SidebarViewModel(content: ContentViewModel())
        #expect(vm.inspectorTab == .exif)
    }

    @Test func inspectorTabChangePersists() {
        clearStoredTab()
        let vm = SidebarViewModel(content: ContentViewModel())
        vm.inspectorTab = .develop

        let stored = UserDefaults.standard.string(forKey: AppSettingsKeys.inspectorTab)
        #expect(stored == SidebarViewModel.InspectorTab.develop.rawValue)

        // 別インスタンスが復元する
        let restored = SidebarViewModel(content: ContentViewModel())
        #expect(restored.inspectorTab == .develop)

        clearStoredTab()
    }

    @Test func showDevelopPanelOpensInspectorAndDevelopTab() {
        clearStoredTab()
        let content = ContentViewModel()
        let vm = SidebarViewModel(content: content)
        vm.isEXIFPanelVisible = false
        vm.inspectorTab = .exif

        vm.showDevelopPanel()

        #expect(vm.inspectorTab == .develop)
        #expect(vm.isEXIFPanelVisible == true)

        clearStoredTab()
    }

    @Test func developViewModelIsSharedInstance() {
        let vm = SidebarViewModel(content: ContentViewModel())
        #expect(vm.developViewModel === vm.developViewModel)
    }
}
