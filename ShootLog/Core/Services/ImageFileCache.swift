import CoreGraphics
import Foundation
import ImageIO

/// 画像ディスクキャッシュで共通する原子的な入出力と容量管理。
enum ImageFileCache {
    struct DiskEntry: Sendable {
        let url: URL
        let size: Int
        let modificationDate: Date
    }

    static func fileURL(forKey key: String, extension fileExtension: String, in directory: URL) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension(fileExtension)
    }

    static func fileURLs(forKey key: String, extensions: [String], in directory: URL) -> [URL] {
        extensions.map { fileURL(forKey: key, extension: $0, in: directory) }
    }

    static func read(
        forKey key: String,
        extensions: [String],
        in directory: URL
    ) -> CGImage? {
        for fileURL in fileURLs(forKey: key, extensions: extensions, in: directory) {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                continue
            }
            touch(fileURL)
            return image
        }
        return nil
    }

    static func write(
        _ image: CGImage,
        type: CFString,
        properties: CFDictionary? = nil,
        to url: URL
    ) -> Bool {
        let temporaryURL = url.deletingPathExtension()
            .appendingPathExtension("\(UUID().uuidString).\(url.pathExtension)")
        guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, type, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return false
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            if (try? fileManager.replaceItemAt(url, withItemAt: temporaryURL)) != nil {
                return true
            }
        } else if (try? fileManager.moveItem(at: temporaryURL, to: url)) != nil {
            return true
        }

        try? fileManager.removeItem(at: temporaryURL)
        // 同一キーを並行生成した別タスクが先に置換していれば、その完成済み画像を採用する。
        return fileManager.fileExists(atPath: url.path)
    }

    static func prepare(directory: URL, extensions: Set<String>) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeInterruptedWriteFiles(in: directory, extensions: extensions)
    }

    static func remove(forKey key: String, extensions: [String], in directory: URL) {
        for fileURL in fileURLs(forKey: key, extensions: extensions, in: directory) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    static func entries(in directory: URL) -> [DiskEntry] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return [] }
        return files.compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else {
                return nil
            }
            return DiskEntry(
                url: fileURL,
                size: values.fileSize ?? 0,
                modificationDate: values.contentModificationDate ?? .distantPast
            )
        }
    }

    static func evict(in directory: URL, maxBytes: Int) {
        let entries = entries(in: directory).sorted { $0.modificationDate < $1.modificationDate }
        var usage = entries.reduce(0) { $0 + $1.size }
        for entry in entries where usage > maxBytes {
            try? FileManager.default.removeItem(at: entry.url)
            usage -= entry.size
        }
    }

    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static func removeInterruptedWriteFiles(in directory: URL, extensions: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in files where isInterruptedWriteFile(fileURL, extensions: extensions) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func isInterruptedWriteFile(_ url: URL, extensions: Set<String>) -> Bool {
        guard extensions.contains(url.pathExtension.lowercased()) else { return false }
        let components = url.deletingPathExtension().lastPathComponent.split(separator: ".")
        guard components.count == 2,
              components[0].count == 64,
              components[0].allSatisfy({ $0.isHexDigit }),
              UUID(uuidString: String(components[1])) != nil else {
            return false
        }
        return true
    }
}
