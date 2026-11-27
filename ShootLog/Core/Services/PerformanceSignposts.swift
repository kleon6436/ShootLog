import Foundation
import os
import Synchronization

// Instruments（os_signpost / Points of Interest）で性能を計測するための区間定義。
// 区間名は計測計画（.omc/plans/macos27-optimization.md §3.2）の受入基準と1対1で対応させ、
// Instruments 上で同じ名前を検索すれば基準値と比較できるようにする。
// signpost は計測していないときほぼコストが無いため、Release ビルドでも残す。
enum PerformanceSignposts {
    static let subsystem = "com.shootlog.app"

    static let folderLoad = OSSignposter(subsystem: subsystem, category: "folderLoad")
    static let viewer = OSSignposter(subsystem: subsystem, category: "viewer")
    static let develop = OSSignposter(subsystem: subsystem, category: "develop")
    static let ai = OSSignposter(subsystem: subsystem, category: "ai")

    /// 開始済みの区間。途中 return の多い async 関数では Optional で持ち、閉じたら nil にして
    /// `defer` 側で未完了の分だけ閉じる（二重に閉じないようにするため）。
    struct Interval {
        fileprivate let signposter: OSSignposter
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState

        func end(cancelled: Bool) {
            if cancelled {
                signposter.endInterval(name, state, "cancelled")
            } else {
                signposter.endInterval(name, state)
            }
        }
    }

    static func begin(_ signposter: OSSignposter, _ name: StaticString) -> Interval {
        Interval(signposter: signposter, name: name, state: signposter.beginInterval(name))
    }

    // 「フォルダを選んでから先頭 N 枚のサムネイルが出るまで」は複数のセルにまたがるため、
    // 区間の開始と、サムネイル表示の数え上げを1か所で管理する
    static let firstThumbnailsTarget = 24
    private static let firstThumbnails = Mutex(FirstThumbnailsState())

    private struct FirstThumbnailsState {
        var generation = 0
        var state: OSSignpostIntervalState?
        var shownCount = 0
        var expectedCount = 0
    }

    /// フォルダ読み込みの開始時に呼ぶ。前の読み込みの区間が未完了なら閉じてから新しい区間を開く。
    static func beginFirstThumbnails(generation: Int) {
        let previous = firstThumbnails.withLock { current -> OSSignpostIntervalState? in
            let previous = current.state
            current = FirstThumbnailsState(
                generation: generation,
                state: folderLoad.beginInterval("folderLoad.selectToFirst24Thumbnails"),
                shownCount: 0,
                expectedCount: firstThumbnailsTarget
            )
            return previous
        }
        if let previous {
            folderLoad.endInterval("folderLoad.selectToFirst24Thumbnails", previous, "superseded")
        }
    }

    /// 写真一覧が確定したときに呼ぶ。写真が N 枚未満のフォルダでも区間を閉じられるようにする。
    static func setFirstThumbnailsExpectedCount(_ count: Int, generation: Int) {
        let finished = firstThumbnails.withLock { current -> OSSignpostIntervalState? in
            guard current.generation == generation, current.state != nil else { return nil }
            current.expectedCount = min(count, firstThumbnailsTarget)
            return takeIfFinished(&current)
        }
        if let finished {
            folderLoad.endInterval("folderLoad.selectToFirst24Thumbnails", finished)
        }
    }

    /// グリッドセルのサムネイルが表示可能になったときに呼ぶ。
    static func markThumbnailShown() {
        let finished = firstThumbnails.withLock { current -> OSSignpostIntervalState? in
            guard current.state != nil else { return nil }
            current.shownCount += 1
            return takeIfFinished(&current)
        }
        if let finished {
            folderLoad.endInterval("folderLoad.selectToFirst24Thumbnails", finished)
        }
    }

    private static func takeIfFinished(_ current: inout FirstThumbnailsState) -> OSSignpostIntervalState? {
        guard current.shownCount >= current.expectedCount, let state = current.state else { return nil }
        current.state = nil
        return state
    }
}
