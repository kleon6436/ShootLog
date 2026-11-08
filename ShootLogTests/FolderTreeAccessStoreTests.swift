import AppKit
import Testing

@testable import ShootLog

// 実際の設定に触れないよう、テストごとに分けた UserDefaults を使う
struct FolderTreeAccessStoreTests {

    private func withStore(_ body: (FolderTreeAccessStore, UserDefaults) throws -> Void) throws {
        let suiteName = "FolderTreeAccessStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(FolderTreeAccessStore(defaults: defaults), defaults)
    }

    private func folder(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    @Test func savesAndReadsGrant() throws {
        try withStore { store, _ in
            #expect(store.grants().isEmpty)

            store.save(folder("/Volumes/X/a"), bookmark: Data("x".utf8))

            let grant = try #require(store.grant(forVolumeOf: folder("/Volumes/X/a/b/c")))
            #expect(grant == FolderTreeAccessGrant(path: "/Volumes/X/a", bookmark: Data("x".utf8)))
        }
    }

    @Test func keepsOneGrantPerVolume() throws {
        try withStore { store, _ in
            store.save(folder("/Volumes/X/a"), bookmark: Data("old".utf8))
            store.save(folder("/Volumes/Y"), bookmark: Data("y".utf8))
            store.save(folder("/Volumes/X"), bookmark: Data("new".utf8))

            #expect(store.grants().count == 2)
            #expect(store.grant(forVolumeOf: folder("/Volumes/X/a"))?.path == "/Volumes/X")
            #expect(store.grant(forVolumeOf: folder("/Volumes/X/a"))?.bookmark == Data("new".utf8))
            #expect(store.grant(forVolumeOf: folder("/Volumes/Y/b"))?.bookmark == Data("y".utf8))
        }
    }

    // "/" の許可は /Volumes/X のフォルダには返さない
    @Test func slashGrantDoesNotMatchOtherVolumes() throws {
        try withStore { store, _ in
            store.save(folder("/"), bookmark: Data("root".utf8))

            #expect(store.grant(forVolumeOf: folder("/Users/a"))?.path == "/")
            #expect(store.grant(forVolumeOf: folder("/Volumes/X/a")) == nil)
        }
    }

    @Test func removesOnlyThatVolume() throws {
        try withStore { store, _ in
            store.save(folder("/"), bookmark: Data("root".utf8))
            store.save(folder("/Volumes/X"), bookmark: Data("x".utf8))

            store.remove(forVolumeOf: folder("/Users/a"))

            #expect(store.grant(forVolumeOf: folder("/Users/a")) == nil)
            #expect(store.grant(forVolumeOf: folder("/Volumes/X/a")) != nil)
        }
    }

    // MARK: - Open Panel の説明文

    @Test func panelMessageWarnsAboutScopeOnlyOnStartupVolume() {
        let startup = FolderTreeAccessPanelDelegate.message(forRoot: folder("/Users/a/photos"))
        let external = FolderTreeAccessPanelDelegate.message(forRoot: folder("/Volumes/DataDisk/a"))

        #expect(startup.key == "openPanel.folderTree.message.startupVolume")
        #expect(external.key == "openPanel.folderTree.message")
    }

    // MARK: - Open Panel 上の検証

    @MainActor @Test func panelAcceptsAncestorOnSameVolume() throws {
        let delegate = FolderTreeAccessPanelDelegate(root: folder("/Volumes/DataDisk/a/photos"))

        try delegate.panel(NSObject(), validate: folder("/Volumes/DataDisk"))
        try delegate.panel(NSObject(), validate: folder("/Volumes/DataDisk/a"))
    }

    @MainActor @Test func panelRejectsInvalidSelectionWithLocalizedReason() throws {
        let delegate = FolderTreeAccessPanelDelegate(root: folder("/Volumes/DataDisk/a/photos"))
        let invalid = [
            "/",
            "/Volumes",
            "/Volumes/Other",
            "/Volumes/DataDisk/a/photos",
            "/Volumes/DataDisk/a/photos/sub",
            "/Volumes/DataDisk/a/other"
        ]

        for path in invalid {
            let error = #expect(throws: ShootLogError.self, "\(path)") {
                try delegate.panel(NSObject(), validate: folder(path))
            }
            #expect(error?.errorDescription == String(localized: "error.folderTreeAccess.notAncestor"))
        }
    }

    @Test func brokenDataReadsAsEmpty() throws {
        try withStore { store, defaults in
            defaults.set(Data("broken".utf8), forKey: AppSettingsKeys.folderTreeAccessGrants)

            #expect(store.grants().isEmpty)
        }
    }
}
