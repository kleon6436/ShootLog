import Photos

/// UI層がPhotoKitの認可状態へ依存しないよう、表示用の分類を提供する。
enum PhotosLibraryPermissionStatus: Equatable, Sendable {
    case authorized
    case limited
    case denied
    case restricted
    case notDetermined
}

/// Phase Aの責務を権限確認に限定し、アセット処理との依存を避ける。
struct PhotosLibraryPermissionService: Sendable {
    func authorizationStatus() -> PhotosLibraryPermissionStatus {
        Self.classify(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotosLibraryPermissionStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.classify(status)
    }

    static func classify(_ status: PHAuthorizationStatus) -> PhotosLibraryPermissionStatus {
        switch status {
        case .authorized:
            return .authorized
        case .limited:
            return .limited
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }
}
