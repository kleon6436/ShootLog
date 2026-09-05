import Foundation
import Testing

@testable import ShootLog

struct PhotosLibraryPhaseBTests {
    @Test @MainActor
    func photoStoresPhotosLibraryIdentifier() {
        let identifier = "A1B2/C3D4"
        let photo = Photo(
            fileURL: URL(fileURLWithPath: "/tmp/placeholder.jpg"),
            phAssetLocalIdentifier: identifier
        )

        #expect(photo.phAssetLocalIdentifier == identifier)
    }

    @Test @MainActor
    func photosLibrarySourceActivatesSidebarMode() {
        let viewModel = ContentViewModel()
        viewModel.currentModeID = "sidebar"
        viewModel.currentPhotoSource = .photosLibrary

        #expect(viewModel.isSidebarModeActive)
    }
}
