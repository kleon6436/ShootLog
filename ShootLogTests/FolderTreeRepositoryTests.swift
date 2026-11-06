import Foundation
import Testing

@testable import ShootLog

struct FolderTreeRepositoryTests {

    /// テストごとに独立した作業ディレクトリを作る
    private func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FolderTreeRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDirectory(_ name: String, in parent: URL) throws {
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    // フォルダだけが返り、隠しフォルダ・パッケージ・シンボリックリンク・ファイルは除外され、
    // "x.jpg" という名前のフォルダはフォルダとして残る
    @Test func returnsOnlyVisibleRealFolders() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try makeDirectory("Normal", in: sandbox)
        try makeDirectory(".hidden", in: sandbox)
        try makeDirectory("Tool.app/Contents", in: sandbox)
        try makeDirectory("x.jpg", in: sandbox)
        try FileManager.default.createSymbolicLink(
            at: sandbox.appendingPathComponent("Link"),
            withDestinationURL: sandbox.appendingPathComponent("Normal", isDirectory: true)
        )
        try Data("x".utf8).write(to: sandbox.appendingPathComponent("photo.jpg"))

        let names = try FolderTreeRepository.childFolders(of: sandbox).map(\.lastPathComponent)

        #expect(names == ["Normal", "x.jpg"])
    }

    // Finder と同じ自然順（"10" が "9" の後）で並ぶ
    @Test func sortsInNaturalOrder() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        for name in ["10", "9", "b", "A", "1"] {
            try makeDirectory(name, in: sandbox)
        }

        let names = try FolderTreeRepository.childFolders(of: sandbox).map(\.lastPathComponent)

        #expect(names == ["1", "9", "10", "A", "b"])
    }

    // 存在しないフォルダはエラーになる（ツリー側で failed として扱う）
    @Test func missingFolderThrows() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        #expect(throws: (any Error).self) {
            try FolderTreeRepository.childFolders(of: sandbox.appendingPathComponent("missing"))
        }
    }
}
