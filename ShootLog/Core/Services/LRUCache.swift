import Foundation

/// 件数上限付きの LRU キャッシュ（値型）。スレッド安全性は持たないため、actor 等の隔離下で使う。
///
/// ヒットした要素と追加・更新した要素をアクセス順の末尾（最新）へ動かし、新しいキーの追加で
/// 上限に達していれば先頭（最古）から退避する。
struct LRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var storage: [Key: Value] = [:]
    /// `storage` のアクセス順（先頭が最古）。
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int { storage.count }

    /// キャッシュヒット時は値を返し、そのキーを最新にする。
    mutating func value(forKey key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    mutating func setValue(_ value: Value, forKey key: Key) {
        if storage[key] == nil {
            while storage.count >= capacity, let victim = order.first {
                order.removeFirst()
                storage.removeValue(forKey: victim)
            }
        }
        storage[key] = value
        touch(key)
    }

    mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    /// キーをアクセス順の末尾（最新）へ動かす。
    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }
}
