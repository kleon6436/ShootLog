import Foundation
import Testing

@testable import ShootLog

@MainActor
struct AnalysisViewModelTests {

    private func makePhotos() -> [Photo] {
        let cameras = ["Camera A", "Camera B", "Camera A", nil, "Camera C"]
        return (0..<10).map { index in
            let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/analysis-\(index).jpg"))
            photo.cameraModel = cameras[index % cameras.count]
            photo.aperture = index.isMultiple(of: 2) ? 2.8 : nil
            photo.iso = index.isMultiple(of: 3) ? 400 : nil
            photo.isFavorite = index.isMultiple(of: 2)
            return photo
        }
    }

    @Test func cachesExifCountAndAvailableCameras() {
        let viewModel = AnalysisViewModel(photos: makePhotos())

        #expect(viewModel.exifCount == 7)
        #expect(viewModel.availableCameras == ["Camera A", "Camera B", "Camera C"])
    }

    @Test func selectedCameraUpdatesFilteredPhotosAndCurrentData() {
        let viewModel = AnalysisViewModel(photos: makePhotos())
        let allData = viewModel.currentData

        viewModel.selectedCamera = "Camera B"

        #expect(viewModel.filteredPhotos.count == 2)
        #expect(viewModel.filteredPhotos.allSatisfy { $0.cameraModel == "Camera B" })
        #expect(
            viewModel.currentData.count != allData.count
                || viewModel.currentData.map(\.label) != allData.map(\.label)
                || viewModel.currentData.map(\.count) != allData.map(\.count)
        )
    }

    @Test func selectedPageAndFavoritesOverlayUpdateCurrentData() {
        let viewModel = AnalysisViewModel(photos: makePhotos())
        let apertureData = viewModel.currentData

        viewModel.selectedPage = .iso
        let isoData = viewModel.currentData
        #expect(isoData.map(\.label) != apertureData.map(\.label))

        viewModel.showFavoritesOverlay = true
        #expect(viewModel.currentData.count > isoData.count)
    }
}
