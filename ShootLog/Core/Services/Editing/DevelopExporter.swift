import CoreGraphics
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

private let developExportLogger = Logger(subsystem: "com.shootlog.app", category: "DevelopExporter")

/// 現像調整を適用した画像を書き出す。
///
/// 保存先の検証 → フル解像度レンダー（回転・トリミング込み）→ メモリエンコード →
/// 直接書き込み の順で進める。原本保護・SMB 対応の書き込み方式は `UpscaleExporter` と同じ。
struct DevelopExporter: Sendable {

    let engine: any ImageDeveloping

    init(engine: any ImageDeveloping = ImageDevelopmentEngine.shared) {
        self.engine = engine
    }

    /// 1 枚を書き出す。
    /// - Parameters:
    ///   - source: 原本ファイル。
    ///   - destination: `NSSavePanel` が返した保存先。
    ///   - rotation: `EditInfo.rotation` 由来（0/90/180/270）。
    ///   - cropRect: `EditInfo.cropRect` 由来の正規化矩形。`nil` でトリミングなし。
    ///   - contentType: 出力形式（JPEG / TIFF）。
    ///   - jpegQuality: JPEG の圧縮品質（0.0〜1.0）。JPEG 以外では無視。
    func export(
        source: URL,
        destination: URL,
        parameters: DevelopParameters,
        rotation: Int,
        cropRect: CGRect?,
        contentType: UTType,
        jpegQuality: Double,
        currentFolder: URL?,
        folderPhotoURLs: [URL]
    ) async throws {
        try UpscaleOutputDestination.validate(
            destination: destination,
            currentFolder: currentFolder,
            photoURLs: folderPhotoURLs
        )

        guard let output = await engine.renderFull(
            url: source,
            parameters: parameters,
            rotation: rotation,
            cropRect: cropRect
        ) else {
            // renderFull はキャンセル時も nil を返すため、キャンセル起因かを先に判定する
            try Task.checkCancellation()
            throw ShootLogError.developRenderFailed
        }
        try Task.checkCancellation()

        let estimatedBytes = output.width * output.height * 4
        guard UpscaleOutputDestination.hasSufficientCapacity(
            at: destination, estimatedBytes: estimatedBytes
        ) else {
            developExportLogger.error(
                "export failed: insufficient capacity at \(destination.path, privacy: .public)"
            )
            throw ShootLogError.developExportFailed
        }

        try await Self.encode(
            output,
            to: destination,
            contentType: contentType,
            sourceURL: source,
            jpegQuality: contentType == .jpeg ? jpegQuality : nil
        )
    }

    // MARK: - エンコード

    /// メモリ上にエンコードしてから `Data.write` で書き込む（`UpscaleExporter` と同じ理由・方式）。
    static func encode(
        _ image: CGImage,
        to url: URL,
        contentType: UTType,
        sourceURL: URL,
        jpegQuality: Double?
    ) async throws {
        let properties = imageProperties(sourceURL: sourceURL, jpegQuality: jpegQuality)
        let handle = Task.detached(priority: .userInitiated) { () throws -> Void in
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, contentType.identifier as CFString, 1, nil
            ) else {
                developExportLogger.error(
                    "export failed: CGImageDestinationCreateWithData returned nil (\(contentType.identifier, privacy: .public))"
                )
                throw ShootLogError.developExportFailed
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                developExportLogger.error("export failed: CGImageDestinationFinalize returned false")
                throw ShootLogError.developExportFailed
            }

            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                try (data as Data).write(to: url, options: [])
            } catch {
                developExportLogger.error(
                    "export failed: Data.write to \(url.path, privacy: .public) — \(error as NSError, privacy: .public)"
                )
                throw ShootLogError.developExportFailed
            }
        }
        try await withTaskCancellationHandler {
            try await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    /// 出力へ付与するメタデータ。原本から撮影日時・カメラ情報をコピーし、ソフトウェアタグを付ける。
    static func imageProperties(sourceURL: URL, jpegQuality: Double?) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFSoftware: softwareTag()]

        if let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let sourceProps = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            if let exif = sourceProps[kCGImagePropertyExifDictionary] {
                properties[kCGImagePropertyExifDictionary] = exif
            }
            if let sourceTIFF = sourceProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFMake] = sourceTIFF[kCGImagePropertyTIFFMake]
                tiff[kCGImagePropertyTIFFModel] = sourceTIFF[kCGImagePropertyTIFFModel]
            }
        }

        properties[kCGImagePropertyTIFFDictionary] = tiff
        if let jpegQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        return properties
    }

    static func softwareTag() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return "ShootLog \(version)"
    }
}
