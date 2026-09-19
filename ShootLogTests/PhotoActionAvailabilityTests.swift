import Foundation
import Testing

@testable import ShootLog

struct PhotoActionAvailabilityTests {

    private func folderPhoto() -> Photo {
        Photo(fileURL: URL(fileURLWithPath: "/tmp/ShootLogTests/IMG_0001.NEF"))
    }

    private func photosLibraryPhoto() -> Photo {
        Photo(
            fileURL: URL(fileURLWithPath: "/tmp/ShootLogTests/icloud-import-v2/ABC123_L0_001.jpg"),
            phAssetLocalIdentifier: "ABC123/L0/001"
        )
    }

    @Test func folderPhotoAllowsEveryAction() {
        let availability = PhotoActionAvailability(photo: folderPhoto(), hasExternalApps: true)

        #expect(availability.hasLocalOriginalFile)
        #expect(availability.canOpenExternally)
        #expect(availability.canCopyPath)
        #expect(availability.canDevelop)
    }

    @Test func photosLibraryPhotoBlocksPathCopyAndDevelop() {
        let availability = PhotoActionAvailability(photo: photosLibraryPhoto(), hasExternalApps: true)

        #expect(availability.hasLocalOriginalFile == false)
        // 外部アプリ起動は実行時にエクスポートしてから開くため、iCloud写真でも可
        #expect(availability.canOpenExternally)
        #expect(availability.canCopyPath == false)
        #expect(availability.canDevelop == false)
    }

    @Test func externalAppActionFollowsAvailableApps() {
        #expect(PhotoActionAvailability(photo: folderPhoto(), hasExternalApps: false).canOpenExternally == false)
        #expect(PhotoActionAvailability(photo: photosLibraryPhoto(), hasExternalApps: false).canOpenExternally == false)
    }

    @Test func externalAppsDefaultsToNone() {
        #expect(PhotoActionAvailability(photo: folderPhoto()).canOpenExternally == false)
    }
}
