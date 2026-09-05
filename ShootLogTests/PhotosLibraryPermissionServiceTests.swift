import Photos
import Testing

@testable import ShootLog

struct PhotosLibraryPermissionServiceTests {
    @Test(arguments: [
        (PHAuthorizationStatus.authorized, PhotosLibraryPermissionStatus.authorized),
        (PHAuthorizationStatus.limited, PhotosLibraryPermissionStatus.limited),
        (PHAuthorizationStatus.denied, PhotosLibraryPermissionStatus.denied),
        (PHAuthorizationStatus.restricted, PhotosLibraryPermissionStatus.restricted),
        (PHAuthorizationStatus.notDetermined, PhotosLibraryPermissionStatus.notDetermined)
    ])
    func classifyPhotoKitStatus(
        status: PHAuthorizationStatus,
        expected: PhotosLibraryPermissionStatus
    ) {
        #expect(PhotosLibraryPermissionService.classify(status) == expected)
    }
}
