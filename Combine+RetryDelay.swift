import Foundation
import Combine

extension Publishers {
    
    struct RetryDelayTimingFunction {
        
        private let f: (Int) -> TimeInterval
        
        init(_ f: @escaping (Int) -> TimeInterval) {
            self.f = f
        }
        
        func callAsFunction(_ n: Int) -> TimeInterval {
            f(n)
        }
    }
}

extension Publishers.RetryDelayTimingFunction {
    
    init(_ delay: TimeInterval) {
        self.init { _ in delay }
    }
}

extension Publishers.RetryDelayTimingFunction {
    
    static func immediate() -> Self { .init(0) }
    static func constant(seconds time: TimeInterval) -> Self { .init(time) }
    static func linearBackoff(unit: TimeInterval) -> Self {
        .init { unit * Double($0) }
    }
    static func exponentialBackoff(unit: TimeInterval) -> Self {
        .init { unit * pow(2.0, Double($0 - 1)) }
    }
}

extension Publishers {
    
    struct RetryDelay<Upstream: Publisher, S: Scheduler>: Publisher {
        
        typealias TimingFunction = Publishers.RetryDelayTimingFunction
        typealias Output = Upstream.Output
        typealias Failure = Upstream.Failure
        
        private let lock = NSLock()
        
        private let upstream: Upstream
        private let retries: Int
        private let limit: Int?
        private let delay: TimingFunction
        private let scheduler: S
        
        init(upstream: Upstream, retries: Int = 0, limit: Int? = nil, delay: TimingFunction, scheduler: S) {
            self.upstream = upstream
            self.retries = retries
            self.limit = limit
            self.delay = delay
            self.scheduler = scheduler
        }
        
        func receive<Downstream: Subscriber>(subscriber: Downstream) where Downstream.Input == Output, Downstream.Failure == Failure {
            upstream
                .catch { error -> AnyPublisher<Output, Failure> in
                    if let limit, retries >= limit {
                        return Fail(error: error).eraseToAnyPublisher()
                    }
                    return Fail(error: error)
                        .delay(for: .seconds(delay(retries + 1)), scheduler: scheduler)
                        .catch { e in
                            RetryDelay(
                                upstream: upstream,
                                retries: retries + 1,
                                limit: limit,
                                delay: delay,
                                scheduler: scheduler
                            )
                        }
                        .eraseToAnyPublisher()
                }
                .subscribe(subscriber)
        }
    }
}

extension Publisher {
    
    func retry<S: Scheduler>(_ retries: Int? = nil, delay: Publishers.RetryDelayTimingFunction, scheduler: S) -> Publishers.RetryDelay<Self, S> {
        .init(upstream: self, retries: 0, limit: retries, delay: delay, scheduler: scheduler)
    }
}

// MARK: - Boring code

var subscription: Set<AnyCancellable> = []

struct IntegerError: Error {}

let publisher = Timer.publish(every: 1, on: .current, in: .common)
    .autoconnect()
    .scan(0) { count, _ in count + 1 }
    .tryMap { int in
        if int > 3 { throw IntegerError() }
        return int
    }

let retry_with_exponential_backoff = publisher
    .retry(3, delay: .exponentialBackoff(unit: 2), scheduler: RunLoop.current)
    .print("[Exponential]")

let retry_with_linear_backoff = publisher
    .retry(3, delay: .linearBackoff(unit: 2), scheduler: RunLoop.current)
    .print("[Linear]")

let retry_with_constant = publisher
    .retry(3, delay: .constant(seconds: 2), scheduler: RunLoop.current)
    .print("[Constant]")

let retry_with_immediate = publisher
    .retry(3, delay: .immediate(), scheduler: RunLoop.current)
    .print("[Immediate]")

retry_with_exponential_backoff
    .sink(receiveCompletion: { _ in print("exponential stream end.") }, receiveValue: { _ in })
    .store(in: &subscription)

retry_with_linear_backoff
    .sink(receiveCompletion: { _ in print("linear stream end.") }, receiveValue: { _ in })
    .store(in: &subscription)

retry_with_constant
    .sink(receiveCompletion: { _ in print("constant stream end.") }, receiveValue: { _ in })
    .store(in: &subscription)

retry_with_immediate
    .sink(receiveCompletion: { _ in print("immediate stream end.") }, receiveValue: { _ in })
    .store(in: &subscription)


