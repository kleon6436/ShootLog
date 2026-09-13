import Testing
import Vision

@testable import ShootLog

struct VisionLabelClassifierTests {

    @Test func 全マッピングキーが実在identifierである() throws {
        let known = Set(try VNClassifyImageRequest
            .knownClassifications(forRevision: VNClassifyImageRequestRevision1)
            .map(\.identifier))

        #expect(VisionLabelClassifier.allMappedIdentifiers.isSubset(of: known))
    }

    @Test func 代表的なidentifierをカテゴリへ分類する() {
        #expect(VisionLabelClassifier.category(for: "dog") == .animal)
        #expect(VisionLabelClassifier.category(for: "birthday_cake") == .food)
        #expect(VisionLabelClassifier.category(for: "living_room") == .indoor)
        #expect(VisionLabelClassifier.category(for: "street_sign") == .text)
        #expect(VisionLabelClassifier.category(for: "balloon_hotair") == .vehicle)
    }

    @Test func 未知のidentifierはunknownになる() {
        #expect(VisionLabelClassifier.category(for: "identifier_not_in_vision_revision_1") == .unknown)
    }
}
