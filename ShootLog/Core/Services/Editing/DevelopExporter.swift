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

    /// 現像結果へさらに超解像を適用する要求。
    struct SuperResolutionRequest: Sendable {
        let engine: any SuperResolutionEngine
        let descriptor: SuperResolutionModelDescriptor
    }

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
    ///   - superResolution: 指定すると現像結果を拡大してから書き出す。`renderFull` が既に回転を
    ///     焼き込むため、超解像エンジンへは常に `rotation: 0` を渡す。
    ///   - upscaleProgress: 超解像段の 0.0〜1.0 の進捗。現像段は速いため通知しない。
    func export(
        source: URL,
        destination: URL,
        parameters: DevelopParameters,
        rotation: Int,
        cropRect: CGRect?,
        contentType: UTType,
        jpegQuality: Double,
        outputColorSpace: CGColorSpace? = nil,
        useRAWParameterMapping: Bool = false,
        usesManualLensCorrection: Bool = false,
        superResolution: SuperResolutionRequest? = nil,
        currentFolder: URL?,
        folderPhotoURLs: [URL],
        upscaleProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try UpscaleOutputDestination.validate(
            destination: destination,
            currentFolder: currentFolder,
            photoURLs: folderPhotoURLs
        )

        guard let developed = await engine.renderFull(
            url: source,
            parameters: parameters,
            rotation: rotation,
            cropRect: cropRect,
            outputColorSpace: outputColorSpace,
            useRAWParameterMapping: useRAWParameterMapping,
            usesManualLensCorrection: usesManualLensCorrection
        ) else {
            // renderFull はキャンセル時も nil を返すため、キャンセル起因かを先に判定する
            try Task.checkCancellation()
            throw ShootLogError.developRenderFailed
        }
        try Task.checkCancellation()

        let output: CGImage
        if let superResolution {
            output = try await Self.upscale(developed, request: superResolution, progress: upscaleProgress)
            try Task.checkCancellation()
        } else {
            output = developed
        }

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
            jpegQuality: contentType == .jpeg ? jpegQuality : nil,
            superResolutionModelID: superResolution?.engine.modelID,
            isTrainedAlgorithmicMedia: superResolution?.descriptor.isTrainedAlgorithmicMedia ?? false
        )
    }

    // MARK: - 超解像段

    /// 現像済み CGImage を超解像エンジンへ通す。回転は現像段で焼き込み済みなので `rotation: 0` 固定。
    private static func upscale(
        _ image: CGImage,
        request: SuperResolutionRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> CGImage {
        let scale = request.engine.scaleFactor
        let outputPixels = image.width * image.height * scale * scale
        try UpscaleExporter.validateOutputSize(pixelCount: outputPixels)

        let transform = PixelCoordinateTransform(
            sourceWidth: image.width * scale,
            sourceHeight: image.height * scale,
            rotation: 0
        )
        guard let buffer = OutputPixelBuffer(
            width: transform.destinationWidth,
            height: transform.destinationHeight
        ) else {
            throw ShootLogError.superResolutionFailed(reason: "output buffer allocation failed")
        }

        let stream = AsyncStream<Double>.makeStream(of: Double.self)
        let forwarder = Task {
            for await fraction in stream.stream { progress?(fraction) }
        }
        defer { forwarder.cancel() }

        do {
            try await request.engine.upscale(image, rotation: 0, into: buffer, progress: stream.continuation)
            stream.continuation.finish()
        } catch {
            stream.continuation.finish()
            throw error
        }

        guard let output = buffer.makeCGImage() else {
            throw ShootLogError.superResolutionFailed(reason: "output image creation failed")
        }
        return output
    }

    // MARK: - エンコード

    /// メモリ上にエンコードしてから `Data.write` で書き込む（`UpscaleExporter` と同じ理由・方式）。
    static func encode(
        _ image: CGImage,
        to url: URL,
        contentType: UTType,
        sourceURL: URL,
        jpegQuality: Double?,
        superResolutionModelID: String? = nil,
        isTrainedAlgorithmicMedia: Bool = false
    ) async throws {
        let properties = imageProperties(
            sourceURL: sourceURL,
            jpegQuality: jpegQuality,
            superResolutionModelID: superResolutionModelID,
            isTrainedAlgorithmicMedia: isTrainedAlgorithmicMedia
        )
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
    /// 超解像を適用した場合はモデル ID をソフトウェアタグへ、学習済みモデルなら IPTC の
    /// DigitalSourceType（AI 生成マーカー）も付ける（`UpscaleExporter` と同じ方式）。
    static func imageProperties(
        sourceURL: URL,
        jpegQuality: Double?,
        superResolutionModelID: String? = nil,
        isTrainedAlgorithmicMedia: Bool = false
    ) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        var tiff: [CFString: Any] = [
            kCGImagePropertyTIFFSoftware: softwareTag(superResolutionModelID: superResolutionModelID)
        ]

        if let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let sourceProps = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            if var exif = sourceProps[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                // トリミング・超解像で寸法が変わるため、EXIF の寸法系は残さない
                // （実ラスタと食い違うメタデータを避ける）。
                exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                properties[kCGImagePropertyExifDictionary] = exif
            }
            if let sourceTIFF = sourceProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFMake] = sourceTIFF[kCGImagePropertyTIFFMake]
                tiff[kCGImagePropertyTIFFModel] = sourceTIFF[kCGImagePropertyTIFFModel]
            }
        }

        properties[kCGImagePropertyTIFFDictionary] = tiff
        if isTrainedAlgorithmicMedia {
            properties[kCGImagePropertyIPTCDictionary] = [
                kCGImagePropertyIPTCExtDigitalSourceType: UpscaleExporter.trainedAlgorithmicMediaURI
            ] as [CFString: Any]
        }
        if let jpegQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        return properties
    }

    static func softwareTag(superResolutionModelID: String? = nil) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        if let superResolutionModelID {
            return "ShootLog \(version) / \(superResolutionModelID)"
        }
        return "ShootLog \(version)"
    }
}
