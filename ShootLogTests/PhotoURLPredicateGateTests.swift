import Foundation
import SwiftData
import Testing

@testable import ShootLog

// syncPhotos を「ストア全件 fetch」から「表示フォルダの URL だけ fetch」に変えてよいかのゲートテスト。
// URL 型の属性を述語に使うと実行時に失敗したり黙って空を返したりした前例があるため、
// インメモリ・ディスク上のストアの両方で、パーセントエンコードが要るパスと非 ASCII のパスを含めて
// 全件走査と同じ集合が返ることを確かめる
@MainActor
struct PhotoURLPredicateGateTests {
    enum StoreKind: CaseIterable {
        case inMemory
        case onDisk
    }

    private static let schema: [any PersistentModel.Type] = [
        Photo.self, EditInfo.self, DevelopSettings.self, DevelopPreset.self,
        FolderHistory.self, IntegrationAppSetting.self,
    ]

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
                .appendingPathComponent("PhotoURLPredicateGateTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let container = try ModelContainer(
                for: Schema(Self.schema),
                configurations: ModelConfiguration(url: directory.appendingPathComponent("store.sqlite"))
            )
            return (ModelContext(container), directory)
        }
    }

    // 1,000枚のフォルダ。空白・記号・日本語・濁点（NFD）を混ぜる
    private static func folderURLs() -> [URL] {
        let folder = URL(fileURLWithPath: "/Volumes/写真 NAS/2026 旅行#1", isDirectory: true)
        return (0..<1_000).map { index in
            let name: String
            switch index % 4 {
            case 0: name = "IMG_\(index).JPG"
            case 1: name = "富士山 \(index).nef"
            case 2: name = "a%b&c \(index).arw"
            default: name = "ガ\u{3099}ス\(index).heic"
            }
            return folder.appendingPathComponent(name)
        }
    }

    @Test(arguments: StoreKind.allCases)
    func urlInPredicateMatchesFullScan(_ kind: StoreKind) throws {
        let (context, directory) = try makeContext(kind)
        defer { directory.map { try? FileManager.default.removeItem(at: $0) } }

        let folderURLs = Self.folderURLs()
        // フォルダの写真のうち 600 枚だけ既に登録済み、別フォルダの写真も 2,000 枚ある状態
        for url in folderURLs.prefix(600) {
            context.insert(Photo(fileURL: url))
        }
        for index in 0..<2_000 {
            context.insert(Photo(fileURL: URL(fileURLWithPath: "/tmp/other folder/\(index).jpg")))
        }
        try context.save()

        let fetched = try context.photos(withFileURLs: folderURLs)
        let scanned = try context.fetch(FetchDescriptor<Photo>()).filter { Set(folderURLs).contains($0.fileURL) }

        #expect(fetched.count == 600)
        #expect(Set(fetched.map(\.persistentModelID)) == Set(scanned.map(\.persistentModelID)))
        #expect(Set(fetched.map(\.fileURL)) == Set(folderURLs.prefix(600)))
    }

    // iCloud 写真の同期で使う「localIdentifier を持つ行だけ」の述語が、フォルダ写真を除いて全件を返すこと
    @Test(arguments: StoreKind.allCases)
    func localIdentifierPredicateReturnsOnlyLibraryPhotos(_ kind: StoreKind) throws {
        let (context, directory) = try makeContext(kind)
        defer { directory.map { try? FileManager.default.removeItem(at: $0) } }

        for index in 0..<50 {
            context.insert(Photo(
                fileURL: URL(fileURLWithPath: "/tmp/icloud/\(index).jpg"),
                phAssetLocalIdentifier: "asset-\(index)/L0/001"
            ))
        }
        for index in 0..<300 {
            context.insert(Photo(fileURL: URL(fileURLWithPath: "/tmp/folder/\(index).jpg")))
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Photo>(
            predicate: #Predicate { $0.phAssetLocalIdentifier != nil }
        ))
        #expect(fetched.count == 50)
        #expect(fetched.allSatisfy { $0.phAssetLocalIdentifier != nil })
    }

    // 保存前に挿入した行も拾えること（段階挿入を途中でキャンセルした直後に同じフォルダを開き直す経路）
    @Test(arguments: StoreKind.allCases)
    func urlInPredicateFindsUnsavedInsert(_ kind: StoreKind) throws {
        let (context, directory) = try makeContext(kind)
        defer { directory.map { try? FileManager.default.removeItem(at: $0) } }

        let folderURLs = Array(Self.folderURLs().prefix(10))
        context.insert(Photo(fileURL: folderURLs[0]))
        try context.save()
        context.insert(Photo(fileURL: folderURLs[1]))

        let fetched = try context.photos(withFileURLs: folderURLs)
        #expect(Set(fetched.map(\.fileURL)) == [folderURLs[0], folderURLs[1]])
    }
}
