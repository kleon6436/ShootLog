import Foundation

// ViewModeRegistry内のViewModeProtocol準拠structはシングルトン配列に1回だけ生成されるが、
// makeViewはモード切替のたび呼ばれる。ここでVMを毎回生成すると状態がリセットされるため、
// 参照型キャッシュとして挟み、初回生成したVMを永続化する
@MainActor
final class ViewModelBox<VM: AnyObject> {
    private var vm: VM?

    // ViewModeProtocol準拠structのプロパティ初期化子（nonisolatedコンテキスト）から
    // デフォルト値として生成できるよう、initだけ明示的にnonisolatedにする
    nonisolated init() {}

    func get(_ make: () -> VM) -> VM {
        if let vm { return vm }
        let created = make()
        vm = created
        return created
    }
}
