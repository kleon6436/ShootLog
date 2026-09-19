import Foundation
import SwiftData
import Testing

@testable import ShootLog

// グリッドの右クリックメニューから非選択の写真を操作したときに、
// アプリ全体の選択（ContentViewModel.selectedPhoto）が動かないことを守る
@MainActor
struct SidebarViewModelPhotoActionTests {

    private func makeSidebarViewModel() throws -> (SidebarViewModel, ModelContext) {
        let container = try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self, DevelopPreset.self,
            FolderHistory.self, IntegrationAppSetting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let content = ContentViewModel()
        content.modelContext = context
        return (SidebarViewModel(content: content), context)
    }

    private func makePhoto(_ name: String, in context: ModelContext) -> Photo {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/ShootLogTests/\(name)"))
        context.insert(photo)
        return photo
    }

    @Test func toggleFavoriteOnOtherPhotoKeepsSelection() throws {
        let (sidebar, context) = try makeSidebarViewModel()
        let photoA = makePhoto("A.jpg", in: context)
        let photoB = makePhoto("B.jpg", in: context)
        sidebar.content.selectedPhoto = photoA

        sidebar.toggleFavorite(photoB)

        #expect(photoB.isFavorite)
        #expect(photoA.isFavorite == false)
        #expect(sidebar.content.selectedPhoto?.id == photoA.id)
    }

    @Test func toggleSuccessTagOnOtherPhotoKeepsSelection() throws {
        let (sidebar, context) = try makeSidebarViewModel()
        let photoA = makePhoto("A.jpg", in: context)
        let photoB = makePhoto("B.jpg", in: context)
        sidebar.content.selectedPhoto = photoA

        sidebar.toggleSuccessTag(.light, for: photoB)

        #expect(photoB.successTags == [.light])
        #expect(photoA.successTags.isEmpty)
        #expect(sidebar.content.selectedPhoto?.id == photoA.id)
    }

    // 選択依存APIを使う項目（回転など）は逆に、対象写真へ選択を移してから実行する
    @Test func performOnPhotoSelectsTargetBeforeRunningAction() async throws {
        let (sidebar, context) = try makeSidebarViewModel()
        let photoA = makePhoto("A.jpg", in: context)
        let photoB = makePhoto("B.jpg", in: context)
        sidebar.content.selectPhoto(photoA)

        var selectionAtActionTime: UUID?
        sidebar.performOnPhoto(photoB) {
            selectionAtActionTime = sidebar.content.selectedPhoto?.id
        }
        // performOnPhoto は次の MainActor サイクルで実行されるため、完了まで譲る
        await Task.yield()

        #expect(selectionAtActionTime == photoB.id)
        #expect(sidebar.content.selectedPhoto?.id == photoB.id)
    }
}
