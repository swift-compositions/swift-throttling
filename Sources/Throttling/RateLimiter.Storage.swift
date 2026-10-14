extension RateLimiter {
    struct Storage<Value: Sendable>: Sendable {
        private let capacity: Int

        private var entries: [Key: Value]

        private var recency: [Key: UInt64]

        private var clock: UInt64

        init(capacity: Int) {
            self.capacity = Swift::max(1, capacity)
            self.entries = [:]
            self.recency = [:]
            self.clock = 0
        }

        var count: Int {
            entries.count
        }

        mutating func cachedValue(for key: Key) -> Value? {
            guard let value = entries[key] else { return nil }
            touch(key)
            return value
        }

        mutating func setValue(_ value: Value, for key: Key) {
            let isNewKey = entries[key] == nil
            entries[key] = value
            touch(key)
            if isNewKey {
                evictIfNeeded()
            }
        }

        @discardableResult
        mutating func removeValue(for key: Key) -> Value? {
            recency[key] = nil
            return entries.removeValue(forKey: key)
        }

        mutating func filter(_ isIncluded: (Key, Value) -> Bool) {
            var removals: [Key] = []
            for (key, value) in entries where !isIncluded(key, value) {
                removals.append(key)
            }
            for key in removals {
                entries[key] = nil
                recency[key] = nil
            }
        }

        private mutating func touch(_ key: Key) {
            clock &+= 1
            recency[key] = clock
        }

        private mutating func evictIfNeeded() {
            while entries.count > capacity {
                guard let leastRecentlyUsed = recency.min(by: { $0.value < $1.value })?.key
                else { return }
                entries[leastRecentlyUsed] = nil
                recency[leastRecentlyUsed] = nil
            }
        }
    }
}
