import Foundation
import Testing

@testable import ShootLog

struct FolderPathComponentsTests {

    // 表示名はパスの末尾をそのまま使い、ファイルシステムに依存させない
    private func make(_ target: String, root: String, isFile: Bool) -> [FolderPathComponent] {
        FolderPathComponents.make(
            targetURL: URL(fileURLWithPath: target),
            rootURL: URL(fileURLWithPath: root),
            isFile: isFile,
            displayName: { $0.lastPathComponent }
        )
    }

    @Test func classifiesComponentsAroundRoot() {
        let components = make("/Users/me/Photos/2024/a.jpg", root: "/Users/me/Photos", isFile: true)

        #expect(components.map(\.name) == ["/", "Users", "me", "Photos", "2024", "a.jpg"])
        #expect(components.map(\.kind) == [
            .outsideRoot, .outsideRoot, .outsideRoot, .folderInRoot, .folderInRoot, .file
        ])
        #expect(components[4].url.path == "/Users/me/Photos/2024")
    }

    // 外部ボリュームは Finder と同じくボリューム自身から始める
    @Test func volumeRootStartsAtVolume() {
        let components = make("/Volumes/X/shoot/a.jpg", root: "/Volumes/X", isFile: true)

        #expect(components.map(\.name) == ["X", "shoot", "a.jpg"])
        #expect(components.map(\.kind) == [.folderInRoot, .folderInRoot, .file])
    }

    @Test func trailingSlashDoesNotChangeResult() {
        let withSlash = make("/a/b/c/", root: "/a/b/", isFile: false)
        let withoutSlash = make("/a/b/c", root: "/a/b", isFile: false)

        #expect(withSlash == withoutSlash)
        #expect(withoutSlash.map(\.kind) == [.outsideRoot, .outsideRoot, .folderInRoot, .folderInRoot])
    }

    @Test func fileDirectlyUnderRoot() {
        let components = make("/a/root/x.png", root: "/a/root", isFile: true)

        #expect(components.map(\.kind) == [.outsideRoot, .outsideRoot, .folderInRoot, .file])
    }

    // 文字列の前方一致ではなくコンポーネント単位で判定する
    @Test func distinguishesSiblingWithSharedPrefix() {
        let components = make("/a/bc/x.jpg", root: "/a/b", isFile: true)

        #expect(components.map(\.kind) == [.outsideRoot, .outsideRoot, .outsideRoot, .file])
        #expect(!FolderPathComponents.isFolder(URL(fileURLWithPath: "/a/bc"), inside: URL(fileURLWithPath: "/a/b")))
        #expect(FolderPathComponents.isFolder(URL(fileURLWithPath: "/a/b/c"), inside: URL(fileURLWithPath: "/a/b")))
        #expect(FolderPathComponents.isFolder(URL(fileURLWithPath: "/a/b/"), inside: URL(fileURLWithPath: "/a/b")))
    }

    // ".." を含むパスは標準化してから判定し、ルートの外へは出さない
    @Test func parentReferenceIsStandardizedBeforeCheck() {
        let root = URL(fileURLWithPath: "/a/b")

        #expect(!FolderPathComponents.isFolder(URL(fileURLWithPath: "/a/b/../c"), inside: root))
        #expect(FolderPathComponents.isSameFolder(URL(fileURLWithPath: "/a/b/c/.."), root))
    }
}
