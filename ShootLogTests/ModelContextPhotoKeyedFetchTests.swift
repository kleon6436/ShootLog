import Foundation
import SwiftData
import Testing

@testable import ShootLog

// 写真 ID の等値述語（ModelContext+PhotoKeyedFetch）が、全件 fetch + first(where:) と同じ結果を返すかの
// ゲートテスト。過去に「UUID 述語が不安定」とされたため、インメモリとディスク上のストアの両方で、
// 保存済みの行・未保存の挿入・存在しない ID を確かめる
@MainActor
struct ModelContextPhotoKeyedFetchTests {
    enum StoreKind: CaseIterable {
        case inMemory
        case onDisk
    }

    private static let schema: [any PersistentModel.Type] = [
        Photo.self, EditInfo.self, DevelopSettings.self, DevelopPreset.self,
        FolderHistory.self, IntegrationAppSetting.self,
    ]

    // ディスク上のストアはテストごとに一時ディレクトリへ作り、終了後に消す
    private func makeContext(_ kind: StoreKind) throws -> (ModelContext, URL?) {
        switch kind {
        case .inMemory:
            let container = try ModelContainer(
                for: Schema(Self.schema),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            return (ModelContext(container), nil)
        case .onDisk:
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ModelContextPhotoKeyedFetchTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let container = try ModelContainer(
                for: Schema(Self.schema),
                configurations: ModelConfiguration(url: directory.appendingPathComponent("store.sqlite"))
            )
            return (ModelContext(container), directory)
        }
    }

    private func removeStore(at directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    @Test(arguments: StoreKind.allCases)
    func editInfoPredicateMatchesFullScan(_ kind: StoreKind) throws {
        let (context, directory) = try makeContext(kind)
        defer { removeStore(at: directory) }

        let photoIDs = (0..<200).map { _ in UUID() }
        for (index, photoID) in photoIDs.enumerated() where index.isMultiple(of: 2) {
            let info = EditInfo(photoID: photoID)
            info.rotation = index
            context.insert(info)
        }
        try context.save()

        for (index, photoID) in photoIDs.enumerated() {
            let viaPredicate = context.editInfo(forPhotoID: photoID)
            let viaScan = try context.fetch(FetchDescriptor<EditInfo>()).first { $0.photoID == photoID }
            #expect(viaPredicate?.persistentModelID == viaScan?.persistentModelID)
            if index.isMultiple(of: 2) {
                #expect(viaPredicate?.rotation == index)
            } else {
                #expect(viaPredicate == nil)
            }
        }
    }

    @Test(arguments: StoreKind.allCases)
    func developSettingsPredicateMatchesFullScan(_ kind: StoreKind) throws {
        let (context, directory) = try makeContext(kind)
        defer { removeStore(at: directory) }

        let photoIDs = (0..<200).map { _ in UUID() }
        for photoID in photoIDs.prefix(100) {
            context.insert(DevelopSettings(photoID: photoID))
        }
        try context.save()

        for (index, photoID) in photoIDs.enumerated() {
            let viaPredicate = context.developSettings(forPhotoID: photoID)
            if index < 100 {
                #expect(viaPredicate?.photoID == photoID)
            } else {
                #expect(viaPredicate == nil)
            }
        }
    }

    // 保存前に挿入した行も、全件 fetch と同じく見つかること（selectPhoto 直後の回転などで起きる）
    @Test(arguments: StoreKind.allCases)
    func predicateFindsUnsavedInsert(_ kind: StoreKind) throws {
        let (context, directory) = try makeContext(kind)
        defer { removeStore(at: directory) }

        let savedID = UUID()
        context.insert(EditInfo(photoID: savedID))
        try context.save()

        let unsavedEditID = UUID()
        let unsavedDevelopID = UUID()
        context.insert(EditInfo(photoID: unsavedEditID))
        context.insert(DevelopSettings(photoID: unsavedDevelopID))

        #expect(context.editInfo(forPhotoID: savedID) != nil)
        #expect(context.editInfo(forPhotoID: unsavedEditID)?.photoID == unsavedEditID)
        #expect(context.developSettings(forPhotoID: unsavedDevelopID)?.photoID == unsavedDevelopID)
    }

    // 削除して保存前の行は返さないこと（resetEdits の直後に引き直す経路）
    @Test(arguments: StoreKind.allCases)
    func predicateSkipsDeletedRow(_ kind: StoreKind) throws {
        let (context, directory) = try makeContext(kind)
        defer { removeStore(at: directory) }

        let photoID = UUID()
        let info = EditInfo(photoID: photoID)
        context.insert(info)
        try context.save()
        context.delete(info)

        #expect(context.editInfo(forPhotoID: photoID) == nil)
    }
}
