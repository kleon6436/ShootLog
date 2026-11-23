import Foundation
import SwiftData
import Testing

@testable import ShootLog

extension Tag {
    // 性能ベンチマーク。Default テストプランでは実行せず、Performance テストプランだけで走らせる
    @Tag static var performance: Self
}

// 性能の基準値を取るためのベンチマーク（.omc/plans/macos27-optimization.md §3）。
// 合否は付けず、計測値を出力する。環境変数 SHOOTLOG_PERF=1（Performance テストプランが設定する）の
// ときだけ有効になり、Default テストプランでは実行されない。xctestplan の selectedTests / skippedTests は
// Swift Testing のテストに効かなかったため、実行対象の絞り込みは次のように -only-testing で行う:
//   xcodebuild ... test -testPlan Performance -only-testing:ShootLogTests/PerformanceBenchmarks
@MainActor
@Suite(
    .tags(.performance),
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["SHOOTLOG_PERF"] == "1")
)
struct PerformanceBenchmarks {
    // F-STORE の規模（計画 §3.1）
    static let otherFolderPhotoCount = 5_000
    static let editInfoCount = 2_000
    static let developSettingsCount = 2_000
    static let measuredSelections = 200

    // 別フォルダの Photo 5,000件と、EditInfo / DevelopSettings 各2,000件を持つストアを作る
    private func makeStore() throws -> (ContentViewModel, ModelContext, [Photo]) {
        let container = try ModelContainer(
            for: Photo.self, EditInfo.self, DevelopSettings.self, DevelopPreset.self,
            FolderHistory.self, IntegrationAppSetting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        var photos: [Photo] = []
        photos.reserveCapacity(Self.otherFolderPhotoCount)
        for index in 0..<Self.otherFolderPhotoCount {
            let photo = Photo(fileURL: URL(fileURLWithPath: "/tmp/ShootLogPerf/other/\(index).jpg"))
            context.insert(photo)
            photos.append(photo)
        }
        for photo in photos.prefix(Self.editInfoCount) {
            context.insert(EditInfo(photoID: photo.id))
        }
        for photo in photos.suffix(Self.developSettingsCount) {
            context.insert(DevelopSettings(photoID: photo.id))
        }
        try context.save()

        let content = ContentViewModel()
        content.modelContext = context
        return (content, context, photos)
    }

    // AC-V2: selectPhoto 内の SwiftData 処理（loadEditInfo + loadDevelopSettings）の1回あたりの時間
    @Test func loadEditStatePerSelection() throws {
        let (content, _, photos) = try makeStore()
        let clock = ContinuousClock()
        var samples: [Duration] = []
        samples.reserveCapacity(Self.measuredSelections)
        // 一定間隔で選び、EditInfo / DevelopSettings の有無が混ざるようにする
        let stride = max(1, photos.count / Self.measuredSelections)
        for index in Swift.stride(from: 0, to: photos.count, by: stride).prefix(Self.measuredSelections) {
            let photo = photos[index]
            let elapsed = clock.measure {
                content.loadEditInfo(for: photo)
                content.loadDevelopSettings(for: photo)
            }
            samples.append(elapsed)
        }
        let report = BenchmarkReport(name: "AC-V2 loadEditState", samples: samples)
        print(report.summary)
        #expect(samples.count == Self.measuredSelections)
    }
}

extension PerformanceBenchmarks {
    static let folderPhotoCount = 1_000
    static let syncRepetitions = 10

    // AC-F2 の補助: syncPhotos が既存の Photo を引く部分。別フォルダの写真 5,000 枚がストアにある状態で、
    // 1,000 枚のフォルダの URL を全件 fetch で引く場合（旧）と URL 述語で引く場合（新）を比べる。
    // 毎回新しいコンテキストで引き、実体化のコストを含めて測る
    @Test func syncPhotosExistingLookup() throws {
        let (_, context, _) = try makeStore()
        let folderURLs = (0..<Self.folderPhotoCount).map {
            URL(fileURLWithPath: "/tmp/ShootLogPerf/folder/\($0).jpg")
        }
        for url in folderURLs { context.insert(Photo(fileURL: url)) }
        try context.save()

        let clock = ContinuousClock()
        var fullScan: [Duration] = []
        var predicate: [Duration] = []
        for _ in 0..<Self.syncRepetitions {
            let fresh = ModelContext(context.container)
            fullScan.append(clock.measure {
                let all = (try? fresh.fetch(FetchDescriptor<Photo>())) ?? []
                _ = Dictionary(all.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
            })
            let fresh2 = ModelContext(context.container)
            predicate.append(clock.measure {
                let rows = (try? fresh2.photos(withFileURLs: folderURLs)) ?? []
                _ = Dictionary(rows.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
            })
        }
        print(BenchmarkReport(name: "AC-F2 syncPhotos lookup (full fetch)", samples: fullScan).summary)
        print(BenchmarkReport(name: "AC-F2 syncPhotos lookup (URL predicate)", samples: predicate).summary)
        #expect(predicate.count == Self.syncRepetitions)
    }
}

// 計測値の中央値・p95 を出力用にまとめる
struct BenchmarkReport {
    let name: String
    let samples: [Duration]

    private var sortedMilliseconds: [Double] {
        samples.map { Double($0.components.seconds) * 1_000 + Double($0.components.attoseconds) / 1e15 }.sorted()
    }

    var median: Double { percentile(0.5) }
    var p95: Double { percentile(0.95) }

    func percentile(_ fraction: Double) -> Double {
        let values = sortedMilliseconds
        guard !values.isEmpty else { return 0 }
        let index = min(values.count - 1, Int((Double(values.count - 1) * fraction).rounded()))
        return values[index]
    }

    var summary: String {
        String(
            format: "[benchmark] %@ n=%d median=%.3fms p95=%.3fms",
            name, samples.count, median, p95
        )
    }
}
