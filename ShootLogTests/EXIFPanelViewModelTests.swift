import Foundation
import Testing

@testable import ShootLog

@MainActor
struct EXIFPanelViewModelTests {

    @Test func dimensionsTextFormatsWidthAndHeight() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.pixelWidth = 6000
        photo.pixelHeight = 4000
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.dimensionsText == "6000 x 4000")
    }

    @Test func dimensionsTextIsNilWhenMissing() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.dimensionsText == nil)
    }

    @Test func fileSizeTextIsNilWhenMissing() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.fileSizeText == nil)
    }

    @Test func fileSizeTextFormatsNonZeroByteCount() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.fileSizeBytes = 25_500_000
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        // ByteCountFormatter の正確な文字列はロケール依存のため、非空であることのみ検証する
        #expect(viewModel.fileSizeText?.isEmpty == false)
    }

    @Test func aiCategoriesReturnsMappedCategoriesFromRawValues() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.aiCategoryRawValues = ["person", "animal"]
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.aiCategories == [.person, .animal])
    }

    @Test func aiCategoriesIsEmptyWhenRawValuesEmpty() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.aiCategories.isEmpty)
    }

    @Test func aiCategoriesIgnoresUnknownRawValues() {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        photo.aiCategoryRawValues = ["person", "not-a-real-category"]
        let viewModel = EXIFPanelViewModel()
        viewModel.photo = photo

        #expect(viewModel.aiCategories == [.person])
    }
}
