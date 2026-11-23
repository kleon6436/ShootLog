import Foundation

// 絞り込み後の写真配列と、写真ID → 配列内の位置の索引をまとめたもの。
// 1回の画面更新で一覧・カウンタ・先読みが同じ配列を何度も参照し、選択位置も毎回探すため、
// 配列と索引を一緒にメモ化して、位置の検索を全件走査ではなく辞書引きにする
struct IndexedPhotoList {
    let photos: [Photo]
    private let indexByID: [UUID: Int]

    init(_ photos: [Photo]) {
        self.photos = photos
        // firstIndex(where:) と同じく、同じIDが重複したら先頭の位置を採る
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(photos.count)
        for (index, photo) in photos.enumerated() where indexByID[photo.id] == nil {
            indexByID[photo.id] = index
        }
        self.indexByID = indexByID
    }

    func index(of photo: Photo?) -> Int? {
        guard let photo else { return nil }
        return indexByID[photo.id]
    }
}
