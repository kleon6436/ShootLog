import Foundation
import SwiftData
import Testing

@testable import ShootLog

@MainActor
struct SidebarViewModelAIFilterTests {

    @Test func emptyAIFilterIncludesEveryPhoto() throws {
        let vm = try makeViewModel()
        let photos = [
            makePhoto(name: "person.jpg", categories: [.person]),
            makePhoto(name: "unknown.jpg", categories: [.unknown])
        ]
        vm.content.photos = photos
        vm.content.resetDetectedAICategories(from: photos)

        #expect(vm.selectedAICategories.isEmpty)
        #expect(vm.displayedPhotos.map(\.id) == photos.map(\.id))
    }

    @Test func selectedAICategoryKeepsOnlyMatchingPhotos() throws {
        let vm = try makeViewModel()
        let photos = [
            makePhoto(name: "person.jpg", categories: [.person]),
            makePhoto(name: "animal.jpg", categories: [.animal]),
            makePhoto(name: "mixed.jpg", categories: [.person, .animal])
        ]
        vm.content.photos = photos
        vm.selectedAICategories = [.person]

        #expect(vm.displayedPhotos.map(\.id) == [photos[0].id, photos[2].id])
    }

    @Test func unknownCategoryDoesNotHidePhotosOrAppearAsAvailableFilter() throws {
        let vm = try makeViewModel()
        let photos = [
            makePhoto(name: "unknown.jpg", categories: [.unknown]),
            makePhoto(name: "person-and-unknown.jpg", categories: [.person, .unknown])
        ]
        vm.content.photos = photos
        vm.content.resetDetectedAICategories(from: photos)

        #expect(!vm.availableAICategories.contains(.unknown))
        #expect(vm.availableAICategories == [.person])

        vm.selectedAICategories = [.person]
        #expect(vm.displayedPhotos.map(\.id) == [photos[1].id])
        vm.selectedAICategories = []
        #expect(vm.displayedPhotos.map(\.id) == photos.map(\.id))
    }

    @Test func availableAICategoriesReflectDetectedCategoriesInDeclarationOrder() throws {
        let vm = try makeViewModel()
        let photos = [
            makePhoto(name: "vehicle.jpg", categories: [.vehicle]),
            makePhoto(name: "plant.jpg", categories: [.plant]),
            makePhoto(name: "unknown.jpg", categories: [.unknown])
        ]
        vm.content.photos = photos
        vm.content.resetDetectedAICategories(from: photos)

        #expect(vm.availableAICategories == [.vehicle, .plant])
        #expect(!vm.availableAICategories.contains(.unknown))
    }

    @Test func favoriteSearchAndAICategoryFiltersAreCombinedWithAND() throws {
        let vm = try makeViewModel()
        let matching = makePhoto(name: "favorite-person.jpg", categories: [.person])
        matching.isFavorite = true
        let notFavorite = makePhoto(name: "favorite-person.jpg", categories: [.person])
        let wrongCategory = makePhoto(name: "favorite-animal.jpg", categories: [.animal])
        wrongCategory.isFavorite = true
        let photos = [matching, notFavorite, wrongCategory]
        vm.content.photos = photos
        vm.showFavoritesOnly = true
        vm.searchText = "favorite-person"
        vm.selectedAICategories = [.person]

        #expect(vm.displayedPhotos.map(\.id) == [matching.id])
    }

    private func makeViewModel() throws -> SidebarViewModel {
        let container = try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self, DevelopPreset.self,
            FolderHistory.self, IntegrationAppSetting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let content = ContentViewModel()
        content.modelContext = context
        return SidebarViewModel(content: content)
    }

    private func makePhoto(
        name: String,
        categories: [AISubjectCategory]
    ) -> Photo {
        let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\(name)"))
        photo.aiCategoryRawValues = categories.map(\.rawValue)
        return photo
    }
}
