import Foundation
import SwiftData

// ライブラリ画面の状態管理。3ステップロードと SwiftData 永続化を制御する
@Observable
@MainActor
final class LibraryViewModel {
    var photos: [Photo] = []
    var isScanning = false
    var scanError: (any Error)?
    var selectedPhoto: Photo?
    var toastMessage: String?

    private var modelContext: ModelContext?
    private var toastTask: Task<Void, Never>?

    // 初回表示時に ModelContext を渡す
    func configure(context: ModelContext) {
        modelContext = context
    }

    // フォルダが変わるたびに呼ぶ。URL スキャン → SwiftData 同期の順で実行する
    func loadFolder(_ folderURL: URL) async {
        guard let context = modelContext else { return }
        isScanning = true
        photos = []
        scanError = nil
        selectedPhoto = nil

        do {
            let urls = try await Task.detached(priority: .utility) {
                try PhotoRepository.scanImageURLs(in: folderURL)
            }.value
            syncPhotos(urls: urls, context: context)
        } catch {
            scanError = error
        }
        isScanning = false
    }

    // お気に入りをトグルしてトーストを表示する
    func toggleFavorite(_ photo: Photo) {
        photo.isFavorite.toggle()
        try? modelContext?.save()
        showToast(photo.isFavorite ? "お気に入りに追加しました" : "お気に入りを解除しました")
    }

    // メモを保存する
    func saveNote(_ note: String, for photo: Photo) {
        photo.note = note
        try? modelContext?.save()
    }

    // Step 3: 選択時に EXIF を遅延ロードして Photo に書き込む
    func loadEXIFIfNeeded(for photo: Photo) async {
        // cameraModel が既にある場合はロード済みとみなす
        guard photo.cameraModel == nil else { return }
        let url = photo.fileURL
        do {
            let exif = try await EXIFService.shared.readEXIF(from: url)
            photo.cameraMake    = exif.cameraMake
            photo.cameraModel   = exif.cameraModel
            photo.lensModel     = exif.lensModel
            photo.aperture      = exif.aperture
            photo.shutterSpeed  = exif.shutterSpeed
            photo.iso           = exif.iso
            photo.focalLength   = exif.focalLength
            photo.colorMode     = exif.colorMode
            if let date = exif.shootingDate { photo.shootingDate = date }
            try? modelContext?.save()
        } catch {
            // EXIF 読み取り失敗は非致命的。無視する
        }
    }

    // MARK: - Private

    // URL リストと SwiftData の Photo を同期する（新規は追加、既存はそのまま）
    private func syncPhotos(urls: [URL], context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Photo>())) ?? []
        let byURL = Dictionary(all.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })

        var result: [Photo] = []
        for url in urls {
            if let existing = byURL[url] {
                result.append(existing)
            } else {
                let photo = Photo(id: UUID(), fileURL: url)
                context.insert(photo)
                result.append(photo)
            }
        }
        photos = result
        try? context.save()
    }

    // トーストを2秒表示して自動消去する
    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toastMessage = nil }
        }
    }
}
