import Testing

@testable import ShootLog

struct LRUCacheTests {

    @Test func returnsStoredValue() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        #expect(cache.value(forKey: "a") == 1)
        #expect(cache.value(forKey: "missing") == nil)
    }

    @Test func evictsLeastRecentlyInsertedWhenFull() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(3, forKey: "c")
        #expect(cache.count == 2)
        #expect(cache.value(forKey: "a") == nil)
        #expect(cache.value(forKey: "b") == 2)
        #expect(cache.value(forKey: "c") == 3)
    }

    @Test func hitMovesKeyToMostRecent() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        _ = cache.value(forKey: "a")
        cache.setValue(3, forKey: "c")
        #expect(cache.value(forKey: "a") == 1)
        #expect(cache.value(forKey: "b") == nil)
    }

    @Test func updatingExistingKeyDoesNotEvict() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(10, forKey: "a")
        #expect(cache.count == 2)
        #expect(cache.value(forKey: "a") == 10)
        #expect(cache.value(forKey: "b") == 2)
    }

    @Test func updatingExistingKeyMakesItMostRecent() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(10, forKey: "a")
        cache.setValue(3, forKey: "c")
        #expect(cache.value(forKey: "b") == nil)
        #expect(cache.value(forKey: "a") == 10)
    }

    @Test func removeAllEmptiesCache() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.value(forKey: "a") == nil)
    }
}
