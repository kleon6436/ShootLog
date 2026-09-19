import SwiftUI

// 写真グリッド（PhotoListView）の右クリックメニューが呼ぶアクション束の組み立て。
// SidebarModeView 本体の肥大化を避けるため別ファイルの extension に分ける
extension SidebarModeView {
    // 選択依存のAPIしか無い操作（外部アプリ起動・現像タブ・回転・コピー）は
    // performOnPhoto で対象写真を選択してから実行する。
    // 一方でお気に入り・成功タグは写真を明示的に受け取る選択非依存のAPIがあるため、
    // 非選択の写真を操作してもビューア・インスペクタの表示対象が飛ばないよう直接呼ぶ。
    // externalApps は Launch Services への照会を伴うため、セルごとではなくここで1度だけ評価する
    var photoContextMenuActions: PhotoContextMenuActions {
        PhotoContextMenuActions(
            externalApps: vm.externalApps,
            openInExternalApp: { photo, adapter in
                vm.performOnPhoto(photo) { vm.openInExternalApp(adapter) }
            },
            toggleFavorite: { photo in
                vm.toggleFavorite(photo)
            },
            toggleSuccessTag: { photo, tag in
                vm.toggleSuccessTag(tag, for: photo)
            },
            showDevelopPanel: { photo in
                vm.performOnPhoto(photo) { vm.showDevelopPanel() }
            },
            rotate: { photo in
                vm.performOnPhoto(photo) { vm.rotateSelectedPhoto() }
            },
            copyFileName: { photo in
                vm.performOnPhoto(photo) { vm.copyFileName() }
            },
            copyFilePath: { photo in
                vm.performOnPhoto(photo) { vm.copyFilePath() }
            }
        )
    }
}
