import Foundation

/// Visionの分類結果を、UIやフィルタで扱う粗粒度カテゴリへ集約する。
enum AISubjectCategory: String, Codable, CaseIterable, Hashable {
    case person
    case animal
    case food
    case landscape
    case building
    case vehicle
    case plant
    case indoor
    case text
    case object
    case unknown

    var displayName: LocalizedStringResource {
        switch self {
        case .person: LocalizedStringResource("ai.category.person")
        case .animal: LocalizedStringResource("ai.category.animal")
        case .food: LocalizedStringResource("ai.category.food")
        case .landscape: LocalizedStringResource("ai.category.landscape")
        case .building: LocalizedStringResource("ai.category.building")
        case .vehicle: LocalizedStringResource("ai.category.vehicle")
        case .plant: LocalizedStringResource("ai.category.plant")
        case .indoor: LocalizedStringResource("ai.category.indoor")
        case .text: LocalizedStringResource("ai.category.text")
        case .object: LocalizedStringResource("ai.category.object")
        case .unknown: LocalizedStringResource("ai.category.unknown")
        }
    }
}
