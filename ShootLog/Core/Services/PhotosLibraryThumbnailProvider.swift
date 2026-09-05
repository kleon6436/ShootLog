import AppKit
import Foundation
import Photos

/// PHAssetのサムネイル要求をSwift concurrencyへ橋渡しするプロバイダ。
actor PhotosLibraryThumbnailProvider {
    static let shared = PhotosLibraryThumbnailProvider()

    func thumbnail(forLocalIdentifier assetLocalIdentifier: String, targetSize: CGSize) async -> NSImage? {
        guard let asset = fetchAsset(localIdentifier: assetLocalIdentifier) else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let state = PHImageManagerRequestState<NSImage>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.setContinuation(continuation)
                let requestID = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: options
                ) { image, _ in
                    _ = state.finish(image)
                }
                state.setRequestID(requestID)
            }
        } onCancel: {
            state.cancel()
        }
    }

    private func fetchAsset(localIdentifier: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return result.firstObject
    }
}

final class PHImageManagerRequestState<Result: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private(set) var requestID: PHImageRequestID?
    private var continuation: CheckedContinuation<Result?, Never>?

    func setContinuation(_ continuation: CheckedContinuation<Result?, Never>) {
        lock.lock()
        self.continuation = continuation
        let shouldCancel = isFinished
        lock.unlock()
        if shouldCancel { continuation.resume(returning: nil) }
    }

    func setRequestID(_ requestID: PHImageRequestID) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isFinished
        lock.unlock()
        if shouldCancel { PHImageManager.default().cancelImageRequest(requestID) }
    }

    func finish(_ result: Result?) -> Bool {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return false
        }
        isFinished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: result)
        return true
    }

    func cancel() {
        lock.lock()
        let requestID = self.requestID
        let continuation = self.continuation
        self.continuation = nil
        isFinished = true
        lock.unlock()
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        continuation?.resume(returning: nil)
    }
}
