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

    // 回転後も写真上の同じ領域が切り抜かれたままになるよう、トリミング矩形も 90° 右回転する
    @Test func rotateTransformsCropRectClockwise() throws {
        let (content, context) = try makeContentViewModel()
        let photo = makePhoto("A.jpg", in: context)
        content.selectPhoto(photo)
        // 左上寄りの横長領域（左上原点・正規化）
        content.setCropRect(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3))

        content.rotateSelectedPhoto()

        // 右回転で左上の領域は右上へ移り、幅と高さが入れ替わる
        let rotated = try #require(content.currentEditInfo?.cropRect)
        #expect(abs(rotated.minX - 0.5) < 1e-9)
        #expect(abs(rotated.minY - 0.1) < 1e-9)
        #expect(abs(rotated.width - 0.3) < 1e-9)
        #expect(abs(rotated.height - 0.5) < 1e-9)
        #expect(content.currentEditInfo?.rotation == 90)
    }

    // 4 回右回転すると元の矩形へ戻る
    @Test func rotatingCropRectFourTimesRestoresOriginal() {
        let original = CGRect(x: 0.15, y: 0.05, width: 0.6, height: 0.4)
        var rect = original
        for _ in 0..<4 { rect = ContentViewModel.cropRectRotatedClockwise(rect) }
        #expect(abs(rect.minX - original.minX) < 1e-9)
        #expect(abs(rect.minY - original.minY) < 1e-9)
        #expect(abs(rect.width - original.width) < 1e-9)
        #expect(abs(rect.height - original.height) < 1e-9)
    }

    // トリミングなし（nil）は回転しても nil のまま
    @Test func rotateKeepsNilCropRect() throws {
        let (content, context) = try makeContentViewModel()
        let photo = makePhoto("A.jpg", in: context)
        content.selectPhoto(photo)

        content.rotateSelectedPhoto()

        #expect(content.currentEditInfo?.cropRect == nil)
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
