# 6.5 Testing concurrent code

## Why it matters
Concurrency bugs are timing bugs, and timing-dependent tests are flaky tests. The goal is **deterministic** tests: no `sleep(1)` hoping that something finished, no reliance on scheduling order, and time that you control. Swift Testing and Swift concurrency together make this practical.

> **How this chapter was verified:** the test snippets were run with `swift test` in a SwiftPM package (Swift 6.4, Swift Testing), and the outputs shown are from those runs. Library code that doesn't import `Testing` is also compiled by this guide's checker.

## Mental model

```
Flaky:          start work → sleep(0.5) → assert           (races the scheduler)
Deterministic:  start work → await its completion → assert
                time-based logic → inject a Clock → advance it manually
                callbacks → confirmation(expectedCount:) around code that finishes inside the closure
```

## Core content

### Async tests and actor isolation
<!-- check: skip -->
```swift
import Testing
@testable import App

@Test func counterIncrementsConcurrently() async {
    let c = Counter()                                         // an actor
    await withTaskGroup { g in
        for _ in 0..<100 { g.addTask { await c.increment() } }
    }
    #expect(await c.value == 100)                            // the group awaited all children: deterministic
}
```

- `@Test` functions can be `async` and `throws`.
- Annotate a test (or a suite) `@MainActor` to test main-actor code synchronously. Each `await` inside it hops as usual.
- Prefer awaiting the real completion (a task group, `await task.value`, a returned value) to observing side effects later.

### `confirmation`: for callbacks and events (verified messages)
<!-- check: skip -->
```swift
@MainActor @Test func notifierCallsBackThreeTimes() async {
    let n = Notifier()
    await confirmation(expectedCount: 3) { saved in
        n.onSaved = { _ in saved() }
        await n.save(count: 3)                                // the events must happen BEFORE this closure returns
    }
}
```

The confirmation is checked when the closure **returns**. Here are the two classic mistakes, with Swift Testing's actual messages:
- Wrong count: `Confirmation was confirmed 3 times, but expected to be confirmed 4 times`
- An event that fires after the closure has returned (for example, from an unawaited `Task { … }` inside it): `Confirmation was confirmed 0 times, but expected to be confirmed 1 time`

`confirmation` is **not** a "wait until called" primitive like XCTest's `expectation` + `wait`. You have to make the closure await whatever triggers the events.

### Controlling time: inject a `Clock`
Code that sleeps, times out, debounces or retries with a delay should take a `Clock`, not call `Task.sleep` directly. In tests, pass a manual clock:

<!-- check: lib -->
```swift
import Synchronization

/// A manually advanced clock for deterministic tests.
public final class ManualClock: Clock, @unchecked Sendable {   // all state is behind the Mutex
    public struct Instant: InstantProtocol {
        public var offset: Duration
        public func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    private struct Sleeper { let deadline: Instant; let continuation: CheckedContinuation<Void, any Error> }
    private let state = Mutex<(now: Instant, sleepers: [Sleeper])>((Instant(offset: .zero), []))

    public init() {}
    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            let fireNow = state.withLock { s -> Bool in
                if deadline <= s.now { return true }
                s.sleepers.append(Sleeper(deadline: deadline, continuation: c))
                return false
            }
            if fireNow { c.resume() }
        }
    }

    public func advance(by d: Duration) {
        let due = state.withLock { s -> [Sleeper] in
            s.now = s.now.advanced(by: d)
            let due = s.sleepers.filter { $0.deadline <= s.now }
            s.sleepers.removeAll { $0.deadline <= s.now }
            return due
        }
        due.forEach { $0.continuation.resume() }            // resume outside the lock
    }
}

public actor Session<C: Clock> where C.Duration == Duration {
    let clock: C
    public private(set) var expired = false
    public init(clock: C) { self.clock = clock }
    public func startTimeout(_ d: Duration) async {
        do { try await clock.sleep(for: d); expired = true } catch {}
    }
}
```

<!-- check: skip -->
```swift
@Test func sessionExpiresDeterministically() async {
    let clock = ManualClock()
    let session = Session(clock: clock)
    let t = Task { await session.startTimeout(.seconds(30)) }
    while clock.sleeperCount == 0 { await Task.yield() }     // wait until the sleep is registered
    #expect(await session.expired == false)
    clock.advance(by: .seconds(30))
    await t.value
    #expect(await session.expired == true)
}
```

The 30-second timeout test **passed in 0.001 s**. In production you pass `ContinuousClock()`.

> This minimal clock ignores cancellation. A production-quality test clock should also resume sleepers with `CancellationError` when their task is cancelled ([2.3](../02-structured-concurrency/03-cancellation.md) shows the pattern). The open-source `swift-clocks` package (Point-Free) provides ready-made `TestClock` and `ImmediateClock` types, if you'd rather not write your own.

### Avoiding flakiness: a checklist
1. **No real sleeps in tests.** Inject clocks.
2. **No "wait a bit and hope" for unstructured tasks.** Expose the `Task` handle (or an `async` method) so the test can `await` it.
3. **Test actors through their public async API.** Don't add synchronous test-only escape hatches.
4. **Run the tests in parallel.** Swift Testing does this by default: two 500 ms `@Test`s finished in 0.517 s under `swift test` (verified). (`swift test --help` says `--no-parallel` is the default, but that flag controls XCTest.) Parallel runs surface shared global state.
5. **Run the suite under Thread Sanitizer regularly** (`swift test --sanitize=thread`).

### XCTest
In XCTest, async test methods work as well (`func testX() async throws`). For expectations, use `await fulfillment(of: [exp], timeout: 1)`, not the blocking `wait(for:timeout:)`. Calling `wait(for:)` from an async test fails to compile (verified): `instance method 'wait' is unavailable from asynchronous contexts; Use await fulfillment(of:timeout:enforceOrder:) instead`. It's unavailable for the same reason `DispatchSemaphore.wait()` is ([0.2](../00-foundations/02-races-deadlocks-inversion.md)).

## Pitfalls
- **`confirmation` with events that fire after the closure** returns (see the message above).
- **Ordering assumptions** about `Task {}` bodies or task-group results.
- **Global singletons** shared between parallel tests.
- **Swallowing errors** in `Task {}` bodies under test. Return them, or record them.

## Under the hood
Swift Testing runs test functions concurrently, as Swift tasks (verified by timing above). A `@MainActor` test runs its body on the main actor, so main-actor tests never run *simultaneously* with each other, but they can still interleave at every `await`. Tests in other domains run in parallel. Use the `.serialized` trait on a suite when its tests must not overlap.

## Exercises
1. Test `SearchModel` from [6.1](01-swiftui.md) with a fake service and a manual clock, so that the 300 ms debounce runs instantly.
2. Make `ManualClock.sleep` cancellation-aware, and write a test proving that cancelling the sleeping task resumes it with `CancellationError`.
3. Turn a flaky test that does `try await Task.sleep(for: .seconds(1)); #expect(model.loaded)` into a deterministic one.

<details><summary>Solutions (outline)</summary>

1. Inject `any Clock<Duration>` (or a generic `C: Clock`) into `SearchModel`, and replace `Task.sleep(for:)` with `clock.sleep(for:)`. In the test, set the query, wait for the sleeper to register, advance 300 ms, and then await the search's completion (expose it as an `async` method, or keep the task handle).
2. Wrap the continuation in `withTaskCancellationHandler`, using the state-machine pattern from [2.3](../02-structured-concurrency/03-cancellation.md). On cancellation, remove the sleeper and resume it with `CancellationError()`.
3. Make `load()` `async`, and `await model.load()` in the test before the `#expect`.
</details>

## Check yourself
1. When does `confirmation(expectedCount:)` check its count?
2. Why inject a `Clock` instead of calling `Task.sleep` directly?
3. Which XCTest API replaces `wait(for:timeout:)` in async tests?

<details><summary>Answers</summary>

1. When its closure returns.
2. So tests can advance time deterministically and instantly.
3. `await fulfillment(of:timeout:)`.
</details>

## Further reading
- Swift Testing documentation: https://developer.apple.com/documentation/testing
- SE-0329 *Clock, Instant, and Duration*
