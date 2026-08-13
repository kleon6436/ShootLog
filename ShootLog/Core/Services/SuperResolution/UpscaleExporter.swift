import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 超解像の書き出しパイプライン全体を組み立てる。
/// 保存先の検証 → 原本のフルデコード → タイル推論 → エンコード → アトミック確定 の順に進む
struct UpscaleExporter: Sendable {

    /// 出力画素数の上限（メガピクセル）。
    /// 出力バッファは1画素あたり Float32 RGBA（16バイト）を消費するため、
    /// この上限がメモリ消費の上限を決める。Phase0.6 の実測で見直す
    static let maximumOutputMegapixels = 160

    /// AI生成物であることを示す IPTC DigitalSourceType の値
    static let trainedAlgorithmicMediaURI =
        "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"

    let engine: any SuperResolutionEngine
    let descriptor: SuperResolutionModelDescriptor

    init(engine: any SuperResolutionEngine, descriptor: SuperResolutionModelDescriptor) {
        self.engine = engine
        self.descriptor = descriptor
    }

    /// 1枚を書き出す。
    /// - Parameters:
    ///   - source: 原本ファイル
    ///   - destination: 保存先（`NSSavePanel` が返した URL）
    ///   - rotation: `EditInfo.rotation` 由来の 0 / 90 / 180 / 270
    ///   - currentFolder: 現在開いているフォルダ（防御1に使う）
    ///   - folderPhotoURLs: 現在フォルダ内の写真 URL 一覧（防御2に使う）
    func export(
        source: URL,
        destination: URL,
        rotation: Int,
        currentFolder: URL?,
        folderPhotoURLs: [URL],
        progress: AsyncStream<Double>.Continuation
    ) async throws {
        try UpscaleOutputDestination.validate(
            destination: destination,
            currentFolder: currentFolder,
            photoURLs: folderPhotoURLs
        )

        let input = try await Self.decodeFullResolution(from: source)
        let outputPixels = input.width * input.height * engine.scaleFactor * engine.scaleFactor
        try Self.validateOutputSize(pixelCount: outputPixels)

        let transform = PixelCoordinateTransform(
            sourceWidth: input.width * engine.scaleFactor,
            sourceHeight: input.height * engine.scaleFactor,
            rotation: rotation
        )
        guard let buffer = OutputPixelBuffer(
            width: transform.destinationWidth,
            height: transform.destinationHeight
        ) else {
            throw ShootLogError.superResolutionFailed(reason: "output buffer allocation failed")
        }

        try await engine.upscale(input, rotation: rotation, into: buffer, progress: progress)

        guard let outputImage = buffer.makeCGImage() else {
            throw ShootLogError.superResolutionFailed(reason: "output image creation failed")
        }

        guard UpscaleOutputDestination.hasSufficientCapacity(
            at: destination, estimatedBytes: outputPixels * 4
        ) else {
            throw ShootLogError.superResolutionExportFailed
        }

        let temporaryURL = UpscaleOutputDestination.makeTemporaryURL(
            pathExtension: destination.pathExtension,
            near: destination
        )
        try await Self.encode(
            outputImage,
            to: temporaryURL,
            contentType: UpscaleOutputDestination.contentType(
                forPathExtension: destination.pathExtension
            ) ?? .jpeg,
            modelID: engine.modelID,
            isTrainedAlgorithmicMedia: descriptor.isTrainedAlgorithmicMedia
        )

        try UpscaleOutputDestination.commit(temporaryURL: temporaryURL, to: destination)
    }

    // MARK: - 上限チェック

    static func validateOutputSize(pixelCount: Int) throws {
        let megapixels = Int((Double(pixelCount) / 1_000_000).rounded(.up))
        guard megapixels <= maximumOutputMegapixels else {
            throw ShootLogError.superResolutionOutputTooLarge(
                outputMegapixels: megapixels, limit: maximumOutputMegapixels
            )
        }
    }

    // MARK: - 原本のデコード

    /// 原本をセンサー解像度のままデコードする。
    /// 埋め込みプレビューではなく実解像度が必要なため、ダウンサンプル系のオプションは使わない。
    /// `Task.detached` はキャンセルを継承しないので、`withTaskCancellationHandler` で明示的に伝播させる
    static func decodeFullResolution(from url: URL) async throws -> CGImage {
        let handle = Task.detached(priority: .userInitiated) { () throws -> CGImage in
            // ブックマーク復元 URL に対してセキュリティスコープを要求する（通常 URL では no-op）
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ShootLogError.superResolutionFailed(reason: "source decode failed")
            }
            return image
        }
        return try await withTaskCancellationHandler {
            try await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    // MARK: - エンコード

    /// 出力画像を一時ファイルへ書き出す。AI生成マーカーもここで付与する
    static func encode(
        _ image: CGImage,
        to url: URL,
        contentType: UTType,
        modelID: String,
        isTrainedAlgorithmicMedia: Bool
    ) async throws {
        let properties = imageProperties(
            modelID: modelID, isTrainedAlgorithmicMedia: isTrainedAlgorithmicMedia
        )
        let handle = Task.detached(priority: .userInitiated) { () throws -> Void in
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, contentType.identifier as CFString, 1, nil
            ) else {
                throw ShootLogError.superResolutionExportFailed
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ShootLogError.superResolutionExportFailed
            }
        }
        try await withTaskCancellationHandler {
            try await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    /// 出力へ付与するメタデータ。
    /// Lanczos は学習済みモデルではないため DigitalSourceType を付与しない
    static func imageProperties(
        modelID: String,
        isTrainedAlgorithmicMedia: Bool
    ) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        properties[kCGImagePropertyTIFFDictionary] = [
            kCGImagePropertyTIFFSoftware: softwareTag(modelID: modelID)
        ] as [CFString: Any]

        // IPTC Extension のキーは IPTC 辞書の下に置く。ImageIO がこれを
        // XMP の Iptc4xmpExt:DigitalSourceType として書き出す
        if isTrainedAlgorithmicMedia {
            properties[kCGImagePropertyIPTCDictionary] = [
                kCGImagePropertyIPTCExtDigitalSourceType: trainedAlgorithmicMediaURI
            ] as [CFString: Any]
        }
        return properties
    }

    static func softwareTag(modelID: String) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return "ShootLog \(version) / \(modelID)"
    }
}
