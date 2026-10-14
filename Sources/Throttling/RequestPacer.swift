public import Foundation

public actor RequestPacer<Key: Hashable & Sendable> {

    public struct ScheduleResult: Sendable {
        public let isAllowed: Bool

        public let scheduledTime: Date

        public let delay: TimeInterval

        public let rateLimitInfo: RateLimiter<Key>.RateLimitResult?

        @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
        public func waitUntilReady() async throws(CancellationError) {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    throw CancellationError()
                }
            }
        }
    }

    public struct Config: Sendable {
        public let targetRate: Double

        public let rateLimiter: RateLimiter<Key>?

        public let allowCatchUp: Bool

        public init(
            targetRate: Double,
            rateLimiter: RateLimiter<Key>? = nil,
            allowCatchUp: Bool = false
        ) {
            self.targetRate = targetRate
            self.rateLimiter = rateLimiter
            self.allowCatchUp = allowCatchUp
        }
    }

    private struct ScheduleInfo {
        var lastScheduledTime: Date?
        var requestCount: Int = 0
    }

    private let config: Config
    private let minSpacing: TimeInterval
    private var schedules: [Key: ScheduleInfo] = [:]

    public init(
        targetRate: Double,
        rateLimiter: RateLimiter<Key>? = nil,
        allowCatchUp: Bool = false
    ) {
        self.config = Config(
            targetRate: targetRate,
            rateLimiter: rateLimiter,
            allowCatchUp: allowCatchUp
        )
        self.minSpacing = 1.0 / targetRate
    }

    public init(config: Config) {
        self.config = config
        self.minSpacing = 1.0 / config.targetRate
    }

    public func scheduleRequest(
        _ key: Key,
        timestamp: Date = Date()
    ) async -> ScheduleResult {
        let rateLimitResult: RateLimiter<Key>.RateLimitResult?
        if let rateLimiter = config.rateLimiter {
            rateLimitResult = await rateLimiter.checkLimit(key, timestamp: timestamp)

            if !rateLimitResult!.isAllowed {
                return ScheduleResult(
                    isAllowed: false,
                    scheduledTime: timestamp,
                    delay: 0,
                    rateLimitInfo: rateLimitResult
                )
            }

            await rateLimiter.recordAttempt(key, timestamp: timestamp)
        } else {
            rateLimitResult = nil
        }

        var info = schedules[key] ?? ScheduleInfo()

        let scheduledTime: Date
        if let lastScheduled = info.lastScheduledTime {
            if config.allowCatchUp {
                scheduledTime = max(timestamp, lastScheduled.addingTimeInterval(minSpacing))
            } else {
                scheduledTime = lastScheduled.addingTimeInterval(minSpacing)
            }
        } else {
            scheduledTime = timestamp
        }

        info.lastScheduledTime = scheduledTime
        info.requestCount += 1
        schedules[key] = info

        let delay = max(0, scheduledTime.timeIntervalSince(timestamp))

        return ScheduleResult(
            isAllowed: true,
            scheduledTime: scheduledTime,
            delay: delay,
            rateLimitInfo: rateLimitResult
        )
    }

    public func reset(_ key: Key) async {
        schedules.removeValue(forKey: key)
    }

    public func resetAll() async {
        schedules.removeAll()
    }

    public func getRequestCount(_ key: Key) async -> Int {
        schedules[key]?.requestCount ?? 0
    }
}
