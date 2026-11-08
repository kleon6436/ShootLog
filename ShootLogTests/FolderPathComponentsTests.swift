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

    // MARK: - ボリュームのルートと許可の検証

    @Test func volumeRootIsDecidedByPath() {
        let cases: [(path: String, expected: String)] = [
            ("/", "/"),
            ("/Users/a", "/"),
            ("/Volumes", "/"),
            ("/Volumes/X", "/Volumes/X"),
            ("/Volumes/X/a/b", "/Volumes/X")
        ]
        for testCase in cases {
            let root = FolderPathComponents.volumeRoot(of: URL(fileURLWithPath: testCase.path))
            #expect(root.path == testCase.expected, "\(testCase.path)")
        }
    }

    @Test func treeAccessMustBeAncestorOnSameVolume() {
        func isValid(_ access: String, root: String) -> Bool {
            FolderPathComponents.isValidTreeAccess(
                URL(fileURLWithPath: access), forRoot: URL(fileURLWithPath: root)
            )
        }

        #expect(isValid("/", root: "/Users/a/photos"))
        #expect(isValid("/Users/a", root: "/Users/a/photos"))
        #expect(isValid("/Volumes/X", root: "/Volumes/X/a/b"))
        #expect(isValid("/Volumes/X/a", root: "/Volumes/X/a/b"))

        // ルート自身・子孫・兄弟は祖先ではない
        #expect(!isValid("/Users/a/photos", root: "/Users/a/photos"))
        #expect(!isValid("/Users/a/photos/sub", root: "/Users/a/photos"))
        #expect(!isValid("/Users/a/phot", root: "/Users/a/photos"))

        // "/" の許可は別ボリュームのルートに使わない
        #expect(!isValid("/", root: "/Volumes/X/a"))
        #expect(!isValid("/Volumes", root: "/Volumes/X/a"))
        #expect(!isValid("/Volumes/Y", root: "/Volumes/X/a"))
    }

    // ".." を含むパスは標準化してから判定し、ルートの外へは出さない
    @Test func parentReferenceIsStandardizedBeforeCheck() {
        let root = URL(fileURLWithPath: "/a/b")

        #expect(!FolderPathComponents.isFolder(URL(fileURLWithPath: "/a/b/../c"), inside: root))
        #expect(FolderPathComponents.isSameFolder(URL(fileURLWithPath: "/a/b/c/.."), root))
    }
}
