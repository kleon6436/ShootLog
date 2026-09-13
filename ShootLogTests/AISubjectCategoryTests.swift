import Foundation
import Testing

@testable import ShootLog

struct AISubjectCategoryTests {

    @Test func allCasesは表示カテゴリとunknownを含む() {
        #expect(AISubjectCategory.allCases.count == 11)
        #expect(Set(AISubjectCategory.allCases) == Set([
            .person, .animal, .food, .landscape, .building, .vehicle,
            .plant, .indoor, .text, .object, .unknown
        ]))
    }

    @Test func displayNameはカテゴリごとに異なるローカライズキーを参照する() {
        let expected: [AISubjectCategory: LocalizedStringResource] = [
            .person: "ai.category.person",
            .animal: "ai.category.animal",
            .food: "ai.category.food",
            .landscape: "ai.category.landscape",
            .building: "ai.category.building",
            .vehicle: "ai.category.vehicle",
            .plant: "ai.category.plant",
            .indoor: "ai.category.indoor",
            .text: "ai.category.text",
            .object: "ai.category.object",
            .unknown: "ai.category.unknown"
        ]

        #expect(expected.count == AISubjectCategory.allCases.count)
        for category in AISubjectCategory.allCases {
            #expect(category.displayName == expected[category])
        }
    }
}
