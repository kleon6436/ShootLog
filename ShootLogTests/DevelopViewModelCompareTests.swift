import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import ShootLog

@MainActor
struct DevelopViewModelCompareTests: DevelopViewModelTesting {

    // MARK: - Before/After スプリット比較

    @Test func enablingSplitCompareRendersAndStoresBeforeImage() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1
        vm.parameters = parameters
        await settle()
        let neutralCallsBeforeCompare = engine.neutralPreviewCallCount

        vm.isComparingSplit = true
        await settle()

        #expect(vm.isComparingSplit)
        #expect(vm.beforeImage != nil)
        #expect(engine.neutralPreviewCallCount == neutralCallsBeforeCompare + 1)
    }

    @Test func splitCompareCannotBeEnabledWithoutPreview() {
        let engine = SpyEngine()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        vm.toggleSplitCompare()

        #expect(vm.isComparingSplit == false)
    }

    @Test func changingParametersDoesNotRerenderBeforeImage() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1
        vm.parameters = parameters
        await settle()
        vm.isComparingSplit = true
        await settle()
        let neutralCallsAfterCompare = engine.neutralPreviewCallCount

        parameters.exposure = 2
        vm.parameters = parameters
        await settle()

        #expect(vm.beforeImage != nil)
        #expect(engine.neutralPreviewCallCount == neutralCallsAfterCompare)
    }

    @Test func changingEditGeometryRefreshesBeforeImageWhileComparing() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1
        vm.parameters = parameters
        await settle()
        vm.isComparingSplit = true
        await settle()
        let neutralCallsBeforeGeometry = engine.neutralPreviewCallCount

        vm.updateEditGeometry(rotation: 90, cropRect: nil)
        #expect(vm.beforeImage == nil)
        await settle()

        #expect(vm.beforeImage != nil)
        #expect(engine.neutralPreviewCallCount > neutralCallsBeforeGeometry)
        #expect(engine.lastRotation == 90)
    }

    @Test func showingFullScreenBeforeDisablesSplitCompare() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1
        vm.parameters = parameters
        await settle()
        vm.toggleSplitCompare()
        await settle()

        vm.isShowingBefore = true

        #expect(vm.isShowingBefore)
        #expect(vm.isComparingSplit == false)
    }

    @Test func loadingAnotherPhotoResetsSplitCompareState() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        let first = Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
        let second = Photo(fileURL: URL(fileURLWithPath: "/tmp/b.jpg"))
        vm.load(photo: first, displaySize: CGSize(width: 800, height: 600))

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1
        vm.parameters = parameters
        await settle()
        vm.toggleSplitCompare()
        vm.splitPosition = 0.2
        engine.previewDelay = 100
        await settle(5)

        vm.load(photo: second, displaySize: CGSize(width: 800, height: 600))
        await settle(150)

        #expect(vm.isComparingSplit == false)
        #expect(vm.splitPosition == 0.5)
        #expect(vm.beforeImage == nil)
    }

    @Test func failedPreviewClearsPreviewButRetainsSplitCompare() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1
        vm.parameters = parameters
        await settle()
        vm.toggleSplitCompare()
        await settle()

        engine.stub = nil
        parameters.exposure = 2
        vm.parameters = parameters
        await settle()

        #expect(vm.previewImage == nil)
        #expect(vm.isComparingSplit)
    }

    @Test func failedBeforeImageEndsSplitCompare() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1
        vm.parameters = parameters
        await settle()

        engine.stub = nil
        vm.isComparingSplit = true
        await settle()

        #expect(vm.isComparingSplit == false)
        #expect(vm.beforeImage == nil)
    }

    @Test func splitPositionClampsToDisplayedImageFrame() {
        let frame = CGRect(x: 100, y: 20, width: 400, height: 300)

        #expect(BeforeAfterSplitView.clampedSplitPosition(locationX: 0, in: frame) == 0)
        #expect(BeforeAfterSplitView.clampedSplitPosition(locationX: 300, in: frame) == 0.5)
        #expect(BeforeAfterSplitView.clampedSplitPosition(locationX: 800, in: frame) == 1)
    }

    @Test func changingPreviewColorSpaceRefreshesBeforeWhileComparing() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))

        var parameters = DevelopParameters.neutral
        parameters.exposure = 1
        vm.parameters = parameters
        await settle()
        vm.isComparingSplit = true
        await settle()
        let neutralCallsBeforeColorSpace = engine.neutralPreviewCallCount
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))

        vm.setPreviewColorSpace(p3)
        await settle()

        #expect(vm.isComparingSplit)
        #expect(vm.beforeImage != nil)
        #expect(engine.neutralPreviewCallCount > neutralCallsBeforeColorSpace)
        #expect(engine.lastPreviewColorSpace.map { CFEqual($0, p3) } == true)
    }

    @Test func updateEditGeometryTriggersRenderWithCrop() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), displaySize: CGSize(width: 800, height: 600))
        await settle()
        #expect(engine.previewCallCount == 1)

        let crop = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        vm.updateEditGeometry(rotation: 0, cropRect: crop)
        await settle()

        #expect(engine.previewCallCount == 2)
        #expect(engine.lastCropRect == crop)
        #expect(vm.previewImage != nil)
    }

    @Test func clearingGeometryWhileNeutralClearsPreview() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(
            photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")),
            displaySize: CGSize(width: 800, height: 600),
            rotation: 90
        )
        await settle()
        #expect(vm.previewImage != nil)

        vm.updateEditGeometry(rotation: 0, cropRect: nil)
        await settle()

        #expect(vm.previewImage == nil)
        #expect(vm.histogram != nil)
    }

    @Test func staleRotationResultIsDiscarded() async throws {
        let engine = SpyEngine()
        engine.stub = makeStubImage()
        let vm = makeViewModel(engine: engine)
        vm.load(
            photo: Photo(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")),
            displaySize: CGSize(width: 800, height: 600),
            rotation: 90
        )
        // デバウンス満了前に回転を変える。古い回転の結果で上書きされないこと。
        vm.updateEditGeometry(rotation: 180, cropRect: nil)
        await settle()

        #expect(engine.lastRotation == 180)
    }
}
