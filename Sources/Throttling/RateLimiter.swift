public import Foundation

public actor RateLimiter<Key: Hashable & Sendable> {

    public struct WindowConfig: Sendable {
        let duration: TimeInterval

        let maxAttempts: Int

        public static func seconds(_ seconds: Int, maxAttempts: Int) -> WindowConfig {
            WindowConfig(duration: TimeInterval(seconds), maxAttempts: maxAttempts)
        }

        public static func minutes(_ minutes: Int, maxAttempts: Int) -> WindowConfig {
            WindowConfig(duration: TimeInterval(minutes * 60), maxAttempts: maxAttempts)
        }

        public static func hours(_ hours: Int, maxAttempts: Int) -> WindowConfig {
            WindowConfig(duration: TimeInterval(hours * 3600), maxAttempts: maxAttempts)
        }

        public init(duration: TimeInterval, maxAttempts: Int) {
            self.duration = duration
            self.maxAttempts = maxAttempts
        }
    }

    struct AttemptInfo: Sendable {
        let windowStart: Date
        var attempts: Int
        var consecutiveFailures: Int
        let timestamp: Date
    }

    public struct RateLimitResult: Sendable {
        public let isAllowed: Bool

        public let currentAttempts: Int

        public let remainingAttempts: Int

        public let nextAllowedAttempt: Date?

        public let backoffInterval: TimeInterval?
    }

    private let windows: [WindowConfig]
    private let maxCacheSize: Int
    private let backoffMultiplier: Double
    private var attemptsByKey: Storage<[AttemptInfo]>
    private let metricsCallback: (@Sendable (Key, RateLimitResult) async -> Void)?

    public init(
        windows: [WindowConfig],
        maxCacheSize: Int = 10000,
        backoffMultiplier: Double = 2.0,
        metricsCallback: (@Sendable (Key, RateLimitResult) async -> Void)? = nil
    ) {
        self.windows = windows.sorted(by: { $0.duration < $1.duration })
        self.maxCacheSize = maxCacheSize
        self.backoffMultiplier = backoffMultiplier
        self.attemptsByKey = Storage(capacity: maxCacheSize)
        self.metricsCallback = metricsCallback
    }

    public func checkLimit(
        _ key: Key,
        timestamp: Date = Date()
    ) async -> RateLimitResult {
        await cleanup(before: timestamp)

        let infos = getCurrentWindows(key: key, timestamp: timestamp)

        if let firstInfo = infos.first,
            firstInfo.consecutiveFailures > 0,
            firstInfo.attempts >= windows[0].maxAttempts
        {
            let backoff = calculateBackoff(consecutiveFailures: firstInfo.consecutiveFailures)
            let nextWindow = firstInfo.windowStart.addingTimeInterval(windows[0].duration)

            let result = RateLimitResult(
                isAllowed: false,
                currentAttempts: firstInfo.attempts,
                remainingAttempts: 0,
                nextAllowedAttempt: nextWindow,
                backoffInterval: backoff
            )

            await metricsCallback?(key, result)
            return result
        }

        for (windowConfig, info) in zip(windows, infos) {
            if info.attempts >= windowConfig.maxAttempts {
                let nextWindow = info.windowStart.addingTimeInterval(windowConfig.duration)

                let backoff =
                    info.consecutiveFailures > 0
                    ? calculateBackoff(consecutiveFailures: info.consecutiveFailures) : nil

                let result = RateLimitResult(
                    isAllowed: false,
                    currentAttempts: info.attempts,
                    remainingAttempts: 0,
                    nextAllowedAttempt: nextWindow,
                    backoffInterval: backoff
                )

                await metricsCallback?(key, result)

                return result
            }
        }

        let result = RateLimitResult(
            isAllowed: true,
            currentAttempts: infos[0].attempts,
            remainingAttempts: windows[0].maxAttempts - infos[0].attempts,
            nextAllowedAttempt: nil,
            backoffInterval: nil
        )

        await metricsCallback?(key, result)
        return result
    }

    public func recordAttempt(_ key: Key, timestamp: Date = Date()) async {
        await cleanup(before: timestamp)

        var infos = getCurrentWindows(key: key, timestamp: timestamp)
        for i in 0..<infos.count {
            infos[i].attempts += 1
        }
        attemptsByKey.setValue(infos, for: key)
    }

    public func recordFailure(_ key: Key) async {
        guard var infos = attemptsByKey.cachedValue(for: key) else { return }
        for i in 0..<infos.count {
            infos[i].consecutiveFailures += 1
        }
        attemptsByKey.setValue(infos, for: key)
    }

    public func recordSuccess(_ key: Key) async {
        guard var infos = attemptsByKey.cachedValue(for: key) else { return }
        for i in 0..<infos.count {
            infos[i].consecutiveFailures = 0
        }
        attemptsByKey.setValue(infos, for: key)
    }

    public func reset(_ key: Key) async {
        _ = attemptsByKey.removeValue(for: key)
    }

    private func getCurrentWindows(key: Key, timestamp: Date) -> [AttemptInfo] {
        let existing = attemptsByKey.cachedValue(for: key) ?? []
        var result: [AttemptInfo] = []

        for (i, window) in windows.enumerated() {
            let windowStart = getWindowStart(for: timestamp, duration: window.duration)

            if i < existing.count && existing[i].windowStart == windowStart {
                result.append(existing[i])
            } else {
                result.append(
                    AttemptInfo(
                        windowStart: windowStart,
                        attempts: 0,
                        consecutiveFailures: existing.first?.consecutiveFailures ?? 0,
                        timestamp: timestamp
                    )
                )
            }
        }

        return result
    }

    private func getWindowStart(for date: Date, duration: TimeInterval) -> Date {
        let windowSeconds = Int(duration)
        let timestamp = Int(date.timeIntervalSince1970)
        let windowStart = timestamp - (timestamp % windowSeconds)
        return Date(timeIntervalSince1970: Double(windowStart))
    }

    private func calculateBackoff(consecutiveFailures: Int) -> TimeInterval? {
        guard consecutiveFailures > 0 else { return nil }
        return pow(backoffMultiplier, Double(consecutiveFailures)) * windows[0].duration
    }

    private func cleanup(before date: Date) async {
        let oldestAllowedDate =
            windows.map { config in
                date.addingTimeInterval(-config.duration)
            }.min() ?? date

        attemptsByKey.filter { _, infos in
            infos.first?.timestamp ?? date > oldestAllowedDate
        }
    }
}
