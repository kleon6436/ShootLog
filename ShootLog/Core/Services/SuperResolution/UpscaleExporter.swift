import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

private let upscaleExportLogger = Logger(subsystem: "com.shootlog.app", category: "UpscaleExporter")

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
    ///   - cropRect: `EditInfo.cropRect` 由来の正規化トリミング矩形（回転適用後に表示されている
    ///     画像基準・左上原点・0...1）。`nil` でトリミングなし。原本を回転前に切り抜いてから
    ///     回転・拡大するため、`DevelopExporter` 経由（現像→超解像チェーン）と同じ構図になる。
    ///   - currentFolder: 現在開いているフォルダ（防御1に使う）
    ///   - folderPhotoURLs: 現在フォルダ内の写真 URL 一覧（防御2に使う）
    ///   - jpegQuality: JPEG の圧縮品質（0.0〜1.0）。JPEG 以外の形式では無視される
    func export(
        source: URL,
        destination: URL,
        rotation: Int,
        cropRect: CGRect? = nil,
        currentFolder: URL?,
        folderPhotoURLs: [URL],
        jpegQuality: Double,
        progress: AsyncStream<Double>.Continuation
    ) async throws {
        try UpscaleOutputDestination.validate(
            destination: destination,
            currentFolder: currentFolder,
            photoURLs: folderPhotoURLs
        )

        let decoded = try await Self.decodeFullResolution(from: source)
        // 回転前の原本を、表示画像基準の矩形へ逆変換して切り抜く。以降のバッファ確保・上限判定は
        // 切り抜き後の画素数で行われるため、トリミング済み写真を等倍以上へ拡大できる。
        let input = Self.cropped(decoded, toDisplayRect: cropRect, rotation: rotation)
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
            upscaleExportLogger.error("export failed: insufficient capacity at \(destination.path, privacy: .public)")
            throw ShootLogError.superResolutionExportFailed
        }

        // 保存先へ直接書き込む。NSSavePanelが付与するPowerboxの権限は選択された
        // ファイルパスそのものにスコープされ、同一ディレクトリ内であっても別名の
        // 一時ファイルを新規作成する権限までは含まれない（ローカルディスクでは
        // 通ることがあるが、SMB等のネットワーク共有では拒否される）。
        // 一時ファイル＋アトミック確定は諦め、直接書き込みに一本化する。
        // さらに`CGImageDestinationCreateWithURL`のURL直書きもSMBでは権限エラーの
        // 原因になりうるため、`encode`内ではメモリエンコード後に`Data.write`で
        // 書き込む方式にしている。
        // 途中で失敗・キャンセルした場合、原本は`validate`が既に守っているため
        // 危険はないが、書きかけの不完全な出力が保存先に残ることは許容する
        // （エラー表示で利用者にわかる形にし、再試行を促す）
        try await Self.encode(
            outputImage,
            to: destination,
            contentType: UpscaleOutputDestination.contentType(
                forPathExtension: destination.pathExtension
            ) ?? .jpeg,
            modelID: engine.modelID,
            isTrainedAlgorithmicMedia: descriptor.isTrainedAlgorithmicMedia,
            jpegQuality: jpegQuality
        )
    }

    // MARK: - トリミング

    /// 「回転適用後に表示されている画像」を基準にした正規化トリミング矩形を、
    /// 回転前の原本 `CGImage` のピクセル矩形へ逆変換して切り抜く。
    ///
    /// 原本を切り抜いてから回転・拡大しても、回転してから切り抜いた構図と一致する
    /// （回転と切り抜きは座標変換の下で可換）。矩形基準は `CropViewModel.normalizedRect` /
    /// `ImageDevelopmentEngine.applyCrop` と同じ（左上原点・0...1）。
    static func cropped(_ image: CGImage, toDisplayRect cropRect: CGRect?, rotation: Int) -> CGImage {
        guard let cropRect,
              cropRect != CGRect(x: 0, y: 0, width: 1, height: 1),
              cropRect.width > 0, cropRect.height > 0 else {
            return image
        }

        let normalized = ((rotation % 360) + 360) % 360
        let x = cropRect.minX
        let y = cropRect.minY
        let w = cropRect.width
        let h = cropRect.height

        // 表示画像 → 原本（回転前）の正規化矩形。90 度刻みなので軸並行のまま。
        let sourceRect: CGRect
        switch normalized {
        case 90:  sourceRect = CGRect(x: y, y: 1 - x - w, width: h, height: w)
        case 180: sourceRect = CGRect(x: 1 - x - w, y: 1 - y - h, width: w, height: h)
        case 270: sourceRect = CGRect(x: 1 - y - h, y: x, width: h, height: w)
        default:  sourceRect = CGRect(x: x, y: y, width: w, height: h)
        }

        let pixelRect = CGRect(
            x: sourceRect.minX * CGFloat(image.width),
            y: sourceRect.minY * CGFloat(image.height),
            width: sourceRect.width * CGFloat(image.width),
            height: sourceRect.height * CGFloat(image.height)
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = pixelRect.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
              let result = image.cropping(to: clamped) else {
            return image
        }
        return result
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

    /// 原本をセンサー解像度のままデコードし、EXIF Orientation を適用して正立させる。
    /// 埋め込みプレビューではなく実解像度が必要なため、ダウンサンプル系のオプションは使わない。
    ///
    /// `rotation` / `cropRect` は表示（Orientation 適用後）の画像を基準にしているため、ここで
    /// 正立させておかないと Orientation 6/8 などの写真でトリミング位置と出力の向きがずれる
    /// （`ImageDevelopmentEngine` も `applyOrientationProperty: true` でデコードしている）。
    ///
    /// Orientation を「ちょうど1回」適用するため、経路を形式で分ける。
    /// - RAW: デコーダによっては既に正立済みの画像を返し、Orientation 属性との関係が形式・OS版で
    ///   揺れる（90° なら縦横比で見分けられるが 180° / 鏡像は見分けられない）。そのため
    ///   `ImageDevelopmentEngine` と同じく `CIRAWFilter` に任せる。`CIRAWFilter` は Orientation を
    ///   自身で1回だけ適用した正立画像を返す。階調を落とさないよう 16bit で実体化する。
    /// - 非RAW（JPEG/HEIC/TIFF/PNG）: `CGImageSourceCreateImageAtIndex` は格納画素をそのまま返す
    ///   契約なので、属性の Orientation を `applyingOrientation` で常に1回適用する（ビット深度は保持）。
    ///
    /// `Task.detached` はキャンセルを継承しないので、`withTaskCancellationHandler` で明示的に伝播させる
    static func decodeFullResolution(from url: URL) async throws -> CGImage {
        let handle = Task.detached(priority: .userInitiated) { () throws -> CGImage in
            // ブックマーク復元 URL に対してセキュリティスコープを要求する（通常 URL では no-op）
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            if ImageDevelopmentEngine.rawExtensions.contains(url.pathExtension.lowercased()) {
                return try UpscaleExporter.decodeRAWUpright(from: url)
            }

            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ShootLogError.superResolutionFailed(reason: "source decode failed")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            guard let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
                  let orientation = CGImagePropertyOrientation(rawValue: rawOrientation),
                  orientation != .up else {
                return image
            }
            guard let oriented = UpscaleExporter.applyingOrientation(image, orientation) else {
                throw ShootLogError.superResolutionFailed(reason: "orientation transform failed")
            }
            return oriented
        }
        return try await withTaskCancellationHandler {
            try await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    /// RAW の正立フル解像度デコード用。作業空間はリニア sRGB、出力は sRGB（超解像エンジンの作業空間と同じ）。
    private static let rawDecodeContext: CIContext = {
        var options: [CIContextOption: Any] = [:]
        if let working = CGColorSpace(name: CGColorSpace.linearSRGB) {
            options[.workingColorSpace] = working
        }
        if let output = SuperResolutionColorSpace.sRGB {
            options[.outputColorSpace] = output
        }
        return CIContext(options: options)
    }()

    /// `CIRAWFilter`（as-shot 既定・等倍）で RAW をデコードし、Orientation 適用済みの 16bit 画像を返す。
    /// `CIImage` は遅延評価なので、呼び出し側のセキュリティスコープ内で実体化まで済ませること。
    private static func decodeRAWUpright(from url: URL) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url),
              let output = filter.outputImage else {
            throw ShootLogError.superResolutionFailed(reason: "source decode failed")
        }
        let rect = output.extent.integral
        guard !rect.isEmpty, !rect.isInfinite,
              let colorSpace = SuperResolutionColorSpace.sRGB ?? CGColorSpace(name: CGColorSpace.sRGB),
              let image = rawDecodeContext.createCGImage(
                output, from: rect, format: .RGBA16, colorSpace: colorSpace
              ) else {
            throw ShootLogError.superResolutionFailed(reason: "source decode failed")
        }
        return image
    }

    /// EXIF Orientation に従って画素を並べ替えた正立画像を返す（Orientation 1 ならそのまま）。
    ///
    /// 変換は「格納画像（左上原点・y 下向き）→ 表示画像」の写像を、CGContext の y 上向き座標へ
    /// 書き直したもの。`w` / `h` は格納画像の寸法。
    static func applyingOrientation(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage? {
        guard orientation != .up else { return image }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let swaps = orientation.swapsDimensions
        let destinationWidth = swaps ? image.height : image.width
        let destinationHeight = swaps ? image.width : image.height

        let transform: CGAffineTransform
        switch orientation {
        case .up:            transform = .identity
        case .upMirrored:    transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down:          transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored:  transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored:  transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right:         transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left:          transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }

        // 階調を落とさないよう、原本のビット深度に合わせた RGBA コンテキストへ描く。
        let colorSpace: CGColorSpace
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput {
            colorSpace = space
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let isFloat = image.bitmapInfo.contains(.floatComponents)
        let bitsPerComponent: Int
        var bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        if isFloat {
            bitsPerComponent = 32
            bitmapInfo |= CGBitmapInfo.floatComponents.rawValue
        } else if image.bitsPerComponent > 8 {
            bitsPerComponent = 16
        } else {
            bitsPerComponent = 8
        }

        guard let context = CGContext(
            data: nil,
            width: destinationWidth,
            height: destinationHeight,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .none
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    // MARK: - エンコード

    /// 出力画像を書き出す。AI生成マーカーもここで付与する。
    /// SMB等のネットワーク共有では`CGImageDestinationCreateWithURL`によるURL直書きが
    /// サンドボックス権限エラーで失敗するため、メモリ上にエンコードしてから
    /// `Data.write`（POSIX write経由）で書き込む。`.atomic`オプションは使わない
    /// （内部で一時ファイル＋renameを使うため、SMBでの権限問題を再度踏む）。
    /// `NSSavePanel`が返すURLは通常startAccessingSecurityScopedResource不要とされるが、
    /// ネットワーク共有では自動付与が効かないことがあるため念のため明示的に呼ぶ
    /// （通常URLではno-op）
    static func encode(
        _ image: CGImage,
        to url: URL,
        contentType: UTType,
        modelID: String,
        isTrainedAlgorithmicMedia: Bool,
        jpegQuality: Double
    ) async throws {
        // 可逆形式（TIFF/PNG）では品質の概念がないため、キー自体を含めない
        let properties = imageProperties(
            modelID: modelID,
            isTrainedAlgorithmicMedia: isTrainedAlgorithmicMedia,
            jpegQuality: contentType == .jpeg ? jpegQuality : nil
        )
        let handle = Task.detached(priority: .userInitiated) { () throws -> Void in
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, contentType.identifier as CFString, 1, nil
            ) else {
                upscaleExportLogger.error("export failed: CGImageDestinationCreateWithData returned nil (contentType=\(contentType.identifier, privacy: .public))")
                throw ShootLogError.superResolutionExportFailed
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                upscaleExportLogger.error("export failed: CGImageDestinationFinalize returned false")
                throw ShootLogError.superResolutionExportFailed
            }

            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                try (data as Data).write(to: url, options: [])
            } catch {
                upscaleExportLogger.error("export failed: Data.write to \(url.path, privacy: .public) — \(error as NSError, privacy: .public)")
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
        isTrainedAlgorithmicMedia: Bool,
        jpegQuality: Double?
    ) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        properties[kCGImagePropertyTIFFDictionary] = [
            kCGImagePropertyTIFFSoftware: softwareTag(modelID: modelID)
        ] as [CFString: Any]

        if let jpegQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }

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

private extension CGImagePropertyOrientation {
    /// 90° / 270° 系で縦横が入れ替わる Orientation か。
    var swapsDimensions: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored: true
        default: false
        }
    }
}
