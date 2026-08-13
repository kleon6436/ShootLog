import Foundation
import ImageIO
import Testing

@testable import ShootLog

struct UpscaleOutputDestinationTests {

    /// テストごとに独立した作業ディレクトリを作る
    private func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("UpscaleOutputDestinationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeFile(_ url: URL, contents: String = "x") throws {
        try Data(contents.utf8).write(to: url)
    }

    /// 大文字小文字を区別しないボリュームかどうか
    private func isCaseInsensitiveVolume(_ directory: URL) throws -> Bool {
        let lower = directory.appendingPathComponent("caseprobe.txt")
        try writeFile(lower)
        defer { try? FileManager.default.removeItem(at: lower) }
        let upper = directory.appendingPathComponent("CASEPROBE.TXT")
        return FileManager.default.fileExists(atPath: upper.path)
    }

    // MARK: - 防御1

    @Test func destinationInsideCurrentFolderIsRejected() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let folder = sandbox.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("IMG_0042_upscaled_4x.jpg")

        #expect(throws: ShootLogError.self) {
            try UpscaleOutputDestination.validate(
                destination: destination, currentFolder: folder, photoURLs: []
            )
        }
    }

    @Test func destinationInsideCurrentFolderIsRejectedViaSymlinkedPath() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let folder = sandbox.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = sandbox.appendingPathComponent("photos-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        // パス文字列は一致しないが実体は同じフォルダなので拒否されること
        let destination = link.appendingPathComponent("out.jpg")
        #expect(throws: ShootLogError.self) {
            try UpscaleOutputDestination.validate(
                destination: destination, currentFolder: folder, photoURLs: []
            )
        }
    }

    @Test func unrelatedDestinationIsAllowed() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let folder = sandbox.appendingPathComponent("photos", isDirectory: true)
        let output = sandbox.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let original = folder.appendingPathComponent("IMG_0042.jpg")
        try writeFile(original)

        try UpscaleOutputDestination.validate(
            destination: output.appendingPathComponent("IMG_0042_upscaled_4x.jpg"),
            currentFolder: folder,
            photoURLs: [original]
        )
    }

    // MARK: - 防御2

    @Test func overwritingOriginalIsRejectedAcrossCaseDifference() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let folder = sandbox.appendingPathComponent("photos", isDirectory: true)
        let output = sandbox.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // 大文字小文字を区別するボリュームではこの経路自体が成立しないため検証をスキップする
        guard try isCaseInsensitiveVolume(folder) else { return }

        let original = folder.appendingPathComponent("IMG_0042.jpg")
        try writeFile(original)

        // 保存先の親は別フォルダなので防御1は通過し、防御2で拒否されること
        let destination = folder.appendingPathComponent("IMG_0042.JPG")
        #expect(throws: ShootLogError.self) {
            try UpscaleOutputDestination.validate(
                destination: destination, currentFolder: output, photoURLs: [original]
            )
        }
    }

    @Test func caseDifferentNamesResolveToSameFileSystemObject() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        guard try isCaseInsensitiveVolume(sandbox) else { return }

        let lower = sandbox.appendingPathComponent("IMG_0042.jpg")
        try writeFile(lower)
        let upper = sandbox.appendingPathComponent("IMG_0042.JPG")

        #expect(UpscaleOutputDestination.isSameFileSystemObject(lower, upper))
        #expect(lower.standardizedFileURL != upper.standardizedFileURL)
    }

    @Test func distinctFilesAreNotConsideredSame() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let first = sandbox.appendingPathComponent("a.jpg")
        let second = sandbox.appendingPathComponent("b.jpg")
        try writeFile(first)
        try writeFile(second)

        #expect(!UpscaleOutputDestination.isSameFileSystemObject(first, second))
    }

    // MARK: - 防御3

    @Test func commitReplacesExistingFileAtomically() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let destination = sandbox.appendingPathComponent("out.bin")
        try writeFile(destination, contents: "old")

        let temporary = UpscaleOutputDestination.makeTemporaryURL(pathExtension: "bin")
        try writeFile(temporary, contents: "new")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try UpscaleOutputDestination.commit(temporaryURL: temporary, to: destination)
        let contents = try String(contentsOf: destination, encoding: .utf8)
        #expect(contents == "new")
    }

    @Test func commitCreatesFileWhenDestinationDoesNotExist() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let destination = sandbox.appendingPathComponent("fresh.bin")
        let temporary = UpscaleOutputDestination.makeTemporaryURL(pathExtension: "bin")
        try writeFile(temporary, contents: "new")

        try UpscaleOutputDestination.commit(temporaryURL: temporary, to: destination)
        let contents = try String(contentsOf: destination, encoding: .utf8)
        #expect(contents == "new")
    }

    // MARK: - 防御5・防御6

    @Test func defaultFileNameAppendsScaleSuffix() {
        let source = URL(fileURLWithPath: "/tmp/photos/IMG_0042.NEF")
        #expect(UpscaleOutputDestination.defaultFileName(for: source, scaleFactor: 4) == "IMG_0042_upscaled_4x")
    }

    @Test func capacityCheckRejectsImplausiblyLargeOutput() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let destination = sandbox.appendingPathComponent("out.tiff")
        #expect(UpscaleOutputDestination.hasSufficientCapacity(at: destination, estimatedBytes: 1024))
        #expect(!UpscaleOutputDestination.hasSufficientCapacity(
            at: destination, estimatedBytes: Int.max / 2
        ))
    }

    // MARK: - 出力サイズ上限

    @Test func outputSizeLimitIsEnforced() {
        #expect(throws: Never.self) {
            try UpscaleExporter.validateOutputSize(pixelCount: 100_000_000)
        }
        #expect(throws: ShootLogError.self) {
            try UpscaleExporter.validateOutputSize(pixelCount: 200_000_000)
        }
    }

    // MARK: - メタデータ

    @Test func lanczosOutputDoesNotClaimAIGeneration() {
        let properties = UpscaleExporter.imageProperties(
            modelID: "lanczos", isTrainedAlgorithmicMedia: false
        )
        #expect(!properties.keys.contains(kCGImagePropertyIPTCDictionary))
        #expect(properties.keys.contains(kCGImagePropertyTIFFDictionary))
    }

    @Test func modelOutputCarriesDigitalSourceType() {
        let properties = UpscaleExporter.imageProperties(
            modelID: "realesrgan-x4", isTrainedAlgorithmicMedia: true
        )
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCExtDigitalSourceType] as? String
            == UpscaleExporter.trainedAlgorithmicMediaURI)
    }
}
