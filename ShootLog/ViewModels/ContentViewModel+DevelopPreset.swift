import Foundation
import SwiftData

// 現像調整プリセットの永続化を担当する。プリセットは写真に紐付かずグローバルに扱う
extension ContentViewModel {
    // MARK: - Develop Preset

    // 保存済みプリセットを sortIndex 昇順でロードする
    func loadDevelopPresets() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<DevelopPreset>(sortBy: [SortDescriptor(\.sortIndex)])
        developPresets = (try? context.fetch(descriptor)) ?? []
    }

    // 現在の調整値を名前付きプリセットとして保存する。名前が空なら既定名を使う
    @discardableResult
    func saveDevelopPreset(name: String, from parameters: DevelopParameters) -> DevelopPreset? {
        guard let context = modelContext else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? String(localized: "develop.preset.defaultName") : trimmed
        let nextIndex = (developPresets.map(\.sortIndex).max() ?? -1) + 1

        let preset = DevelopPreset(name: finalName, parameters: parameters, sortIndex: nextIndex)
        do {
            // 明示的にエンコードし直し、NaN/Inf を含む調整値で無言の失敗にならないようにする
            try preset.setParameters(parameters)
        } catch {
            self.error = ShootLogError.photoDataSaveFailed
            return nil
        }
        context.insert(preset)
        guard saveOrReportError(context) else { return nil }
        loadDevelopPresets()
        return preset
    }

    func deleteDevelopPreset(_ preset: DevelopPreset) {
        guard let context = modelContext else { return }
        context.delete(preset)
        _ = saveOrReportError(context)
        loadDevelopPresets()
    }

    func renameDevelopPreset(_ preset: DevelopPreset, to name: String) {
        guard let context = modelContext else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != preset.name else { return }
        preset.name = trimmed
        _ = saveOrReportError(context)
        loadDevelopPresets()
    }
}
