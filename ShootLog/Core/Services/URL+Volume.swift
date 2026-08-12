import Foundation

extension URL {
    // ボリュームがネットワーク接続かどうかを判定する（取得失敗時はローカル扱いとする）
    var isOnNetworkVolume: Bool {
        let isLocal = (try? resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
        return !isLocal
    }
}
