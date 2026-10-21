public import Foundation

public struct ThrottledClient<Key: Hashable & Sendable>: Sendable {

    public struct AcquisitionResult: Sendable {
        public let canProceed: Bool

        public let scheduledTime: Date?

        public let delay: TimeInterval

        public let retryAfter: TimeInterval?

        public let rateLimitResult: RateLimiter<Key>.RateLimitResult?

        public let pacingResult: RequestPacer<Key>.ScheduleResult?

        @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
        public func waitUntilReady() async throws(CancellationError) {
            guard canProceed, delay > 0 else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                throw CancellationError()
            }
        }
    }

    public let rateLimiter: RateLimiter<Key>?

    public let pacer: RequestPacer<Key>?

    public init(
        rateLimiter: RateLimiter<Key>? = nil,
        pacer: RequestPacer<Key>? = nil
    ) {
        self.rateLimiter = rateLimiter
        self.pacer = pacer
    }

    public init(
        windows: [RateLimiter<Key>.WindowConfig],
        targetRate: Double,
        backoffMultiplier: Double = 2.0
    ) {
        self.rateLimiter = RateLimiter(
            windows: windows,
            backoffMultiplier: backoffMultiplier
        )
        self.pacer = RequestPacer(
            targetRate: targetRate,
            rateLimiter: nil
        )
    }

    public func acquire(
        _ key: Key,
        timestamp: Date = Date()
    ) async -> AcquisitionResult {
        let rateLimitResult: RateLimiter<Key>.RateLimitResult?
        if let rateLimiter {
            let checked = await rateLimiter.checkLimit(key, timestamp: timestamp)
            rateLimitResult = checked

            if !checked.isAllowed {
                let retryAfter =
                    checked.backoffInterval
                    ?? checked.nextAllowedAttempt?.timeIntervalSince(timestamp)

                return AcquisitionResult(
                    canProceed: false,
                    scheduledTime: nil,
                    delay: 0,
                    retryAfter: retryAfter,
                    rateLimitResult: rateLimitResult,
                    pacingResult: nil
                )
            }

            await rateLimiter.recordAttempt(key, timestamp: timestamp)
        } else {
            rateLimitResult = nil
        }

        guard let pacer else {
            return AcquisitionResult(
                canProceed: true,
                scheduledTime: timestamp,
                delay: 0,
                retryAfter: nil,
                rateLimitResult: rateLimitResult,
                pacingResult: nil
            )
        }

        let pacingResult = await pacer.scheduleRequest(key, timestamp: timestamp)

        return AcquisitionResult(
            canProceed: true,
            scheduledTime: pacingResult.scheduledTime,
            delay: pacingResult.delay,
            retryAfter: nil,
            rateLimitResult: rateLimitResult,
            pacingResult: pacingResult
        )
    }

    public func recordSuccess(_ key: Key) async {
        await rateLimiter?.recordSuccess(key)
    }

    public func recordFailure(_ key: Key) async {
        await rateLimiter?.recordFailure(key)
    }

    public func reset(_ key: Key) async {
        await rateLimiter?.reset(key)
        await pacer?.reset(key)
    }
}
