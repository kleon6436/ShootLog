import Foundation
import Testing

@testable import ShootLog

@MainActor
struct HighResPrefetcherTests {

    // fake の /tmp パスはボリュームルートが取れずローカル扱い（localRadius = 3）になる。
    private func photos(_ count: Int) -> [Photo] {
        (0..<count).map { Photo(fileURL: URL(fileURLWithPath: "/tmp/prefetch-\($0).jpg")) }
    }

    @Test func returnsEmptyForDegenerateInput() {
        #expect(HighResPrefetcher.neighborURLs(in: photos(1), around: 0).isEmpty)
        #expect(HighResPrefetcher.neighborURLs(in: photos(5), around: nil).isEmpty)
        #expect(HighResPrefetcher.neighborURLs(in: [], around: 0).isEmpty)
        #expect(HighResPrefetcher.neighborURLs(in: photos(5), around: 9).isEmpty)
    }

    @Test func localVolumeUsesRadiusThreeWithForwardFirstOrdering() {
        let list = photos(10)
        let urls = HighResPrefetcher.neighborURLs(in: list, around: 4)
        // distance ごとに forward → backward: 5, 3, 6, 2, 7, 1
        #expect(urls == [5, 3, 6, 2, 7, 1].map { list[$0].fileURL })
    }

    @Test func clampsRadiusNearStart() {
        let list = photos(10)
        let urls = HighResPrefetcher.neighborURLs(in: list, around: 1)
        // forward 2,3,4 / backward 0（-1,-2 は範囲外）: 2, 0, 3, 4
        #expect(urls == [2, 0, 3, 4].map { list[$0].fileURL })
    }

    @Test func clampsRadiusNearEndWithoutWrap() {
        let list = photos(10)
        let urls = HighResPrefetcher.neighborURLs(in: list, around: 8)
        // forward 9（10,11 は範囲外・wrap なし）/ backward 7,6,5: 9, 7, 6, 5
        #expect(urls == [9, 7, 6, 5].map { list[$0].fileURL })
    }

    @Test func forwardWrapsWhenEnabledBackwardDoesNot() {
        let list = photos(10)
        let urls = HighResPrefetcher.neighborURLs(in: list, around: 8, wrapsAround: true)
        // forward 9, 0(wrap), 1(wrap) / backward 7, 6, 5
        #expect(urls == [9, 7, 0, 6, 1, 5].map { list[$0].fileURL })
    }

    @Test func deduplicatesAndExcludesCurrentIndexOnSmallWrappingList() {
        let list = photos(3)
        let urls = HighResPrefetcher.neighborURLs(in: list, around: 1, wrapsAround: true)
        // radius は count-1=2 に丸められる。forward 2, 0(wrap) / backward 0(既出), -1→なし
        #expect(urls == [list[2].fileURL, list[0].fileURL])
        #expect(Set(urls).count == urls.count)
    }
}
