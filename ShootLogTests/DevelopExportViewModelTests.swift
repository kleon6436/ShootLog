import CoreGraphics
import Foundation
import Testing

@testable import ShootLog

@MainActor
struct DevelopExportViewModelTests {

    @Test func sizeLimitIsNotEnforcedWhenSuperResolutionOff() {
        let vm = DevelopExportViewModel(
            inputPixelSize: CGSize(width: 12_000, height: 12_000),
            croppedInputPixelSize: CGSize(width: 12_000, height: 12_000)
        )
        vm.applySuperResolution = false
        #expect(vm.exceedsSizeLimit == false)
        #expect(vm.canStart)
    }

    @Test func exceedsSizeLimitForLargeInputAtHighScale() {
        let vm = DevelopExportViewModel(
            inputPixelSize: CGSize(width: 8_000, height: 6_000),
            croppedInputPixelSize: CGSize(width: 8_000, height: 6_000)
        )
        vm.applySuperResolution = true
        vm.superResolutionScale = .quadruple
        // 8000*6000*16 = 768MP > 160MP 上限
        #expect(vm.exceedsSizeLimit)
        #expect(vm.canStart == false)
        #expect(vm.canReduceSuperResolutionScale)
    }

    @Test func reduceScaleDropsToDouble() {
        let vm = DevelopExportViewModel(
            inputPixelSize: CGSize(width: 8_000, height: 6_000),
            croppedInputPixelSize: CGSize(width: 8_000, height: 6_000)
        )
        vm.applySuperResolution = true
        vm.superResolutionScale = .quadruple
        vm.reduceSuperResolutionScale()
        #expect(vm.superResolutionScale == .double)
        // 8000*6000*4 = 192MP、まだ上限超過
        #expect(vm.exceedsSizeLimit)
    }

    @Test func estimatedOutputUsesCroppedSize() {
        let vm = DevelopExportViewModel(
            inputPixelSize: CGSize(width: 6_000, height: 4_000),
            croppedInputPixelSize: CGSize(width: 3_000, height: 2_000)
        )
        vm.applySuperResolution = true
        vm.superResolutionScale = .double
        // 3000*2000*4 = 24MP、上限内
        #expect(vm.estimatedOutputPixelCount == 24_000_000)
        #expect(vm.exceedsSizeLimit == false)
        #expect(vm.canStart)
    }

    @Test func unknownInputSizeDoesNotBlock() {
        let vm = DevelopExportViewModel(inputPixelSize: nil, croppedInputPixelSize: nil)
        vm.applySuperResolution = true
        vm.superResolutionScale = .quadruple
        #expect(vm.estimatedOutputPixelCount == nil)
        #expect(vm.exceedsSizeLimit == false)
        #expect(vm.canStart)
    }

    @Test func progressUpdatesAdvanceStageToUpscaling() {
        let vm = DevelopExportViewModel()
        vm.state = .running
        vm.beginProcessing()
        #expect(vm.stage == .developing)

        vm.updateUpscaleProgress(0.4)
        #expect(vm.stage == .upscaling)
        #expect(vm.upscaleProgress == 0.4)

        // running 以外では進捗を受け付けない
        vm.state = .finished(URL(fileURLWithPath: "/tmp/x.jpg"))
        vm.updateUpscaleProgress(0.9)
        #expect(vm.upscaleProgress == 0.4)
    }

    @Test func effectiveColorSpaceForcesSRGBWhenSuperResolutionOn() {
        let vm = DevelopExportViewModel()
        vm.colorSpace = .displayP3

        vm.applySuperResolution = false
        #expect(vm.effectiveColorSpace == .displayP3)

        vm.applySuperResolution = true
        #expect(vm.effectiveColorSpace == .sRGB)
    }

    @Test func availableScalesMatchBundledAIModels() {
        let vm = DevelopExportViewModel()
        let expected = UpscaleExportViewModel.ScaleFactor.allCases.filter {
            SuperResolutionModelCatalog.aiModel(forScaleFactor: $0.rawValue) != nil
        }
        #expect(vm.availableSuperResolutionScales == expected)
    }
}
