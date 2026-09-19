import Foundation
import SwiftData
import Testing

@testable import ShootLog

@MainActor
struct ContentViewModelEditTests {

    private func makeContentViewModel() throws -> (ContentViewModel, ModelContext) {
        let container = try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self, DevelopPreset.self,
            FolderHistory.self, IntegrationAppSetting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let content = ContentViewModel()
        content.modelContext = context
        return (content, context)
    }

    private func makePhoto(_ name: String, in context: ModelContext) -> Photo {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/ShootLogTests/\(name)"))
        context.insert(photo)
        return photo
    }

    // selectedPhoto へ直接代入して currentEditInfo が前の写真のまま残っている状態でも、
    // 回転が選択中写真の EditInfo だけに適用されることを確かめる。
    // selectPhoto(_:) 経由だと loadEditInfo が必ず走って必ず成功するため、
    // ガード自体を検証するには直接代入で組み立てる必要がある
    @Test func rotateAppliesOnlyToCurrentlySelectedPhoto() throws {
        let (content, context) = try makeContentViewModel()
        let photoA = makePhoto("A.jpg", in: context)
        let photoB = makePhoto("B.jpg", in: context)

        content.selectPhoto(photoA)
        content.rotateSelectedPhoto()

        content.selectedPhoto = photoB
        content.rotateSelectedPhoto()

        let all = try context.fetch(FetchDescriptor<EditInfo>())
        let infoA = all.filter { $0.photoID == photoA.id }
        let infoB = all.filter { $0.photoID == photoB.id }

        #expect(infoA.count == 1)
        #expect(infoA.first?.rotation == 90)
        #expect(infoB.count == 1)
        #expect(infoB.first?.rotation == 90)
    }

    // 既存行がある写真へ直接切り替えた場合は、重複行を作らず既存行を更新する
    @Test func rotateReusesStoredEditInfoWithoutDuplicating() throws {
        let (content, context) = try makeContentViewModel()
        let photoA = makePhoto("A.jpg", in: context)
        let photoB = makePhoto("B.jpg", in: context)

        content.selectPhoto(photoB)
        content.rotateSelectedPhoto()
        content.selectPhoto(photoA)
        content.rotateSelectedPhoto()

        content.selectedPhoto = photoB
        content.rotateSelectedPhoto()

        let all = try context.fetch(FetchDescriptor<EditInfo>())
        #expect(all.count == 2)
        #expect(all.first { $0.photoID == photoA.id }?.rotation == 90)
        #expect(all.first { $0.photoID == photoB.id }?.rotation == 180)
    }

    @Test func selectPhotoLeavesCropMode() throws {
        let (content, context) = try makeContentViewModel()
        let photo = makePhoto("A.jpg", in: context)
        content.selectPhoto(photo)
        content.toggleCropMode()
        #expect(content.isCropMode)

        content.selectPhoto(makePhoto("B.jpg", in: context))

        #expect(content.isCropMode == false)
    }
}
