# 7.5 Clocks, time, timeouts

## Why it matters
Sleeping, timeouts, debouncing, retry backoff, measuring: all time-based concurrency goes through the `Clock` protocol (SE-0329). Choosing the right clock matters when the device sleeps. Abstracting over clocks is what makes time-based code testable ([6.5](../06-apps/05-testing.md)). And timeouts, which are surprisingly subtle, are built from clocks and cancellation.

## Mental model

```
protocol Clock<Duration> { associatedtype Instant; var now: Instant; func sleep(until:tolerance:) async throws }

ContinuousClock   keeps counting while the device is asleep   ("wall-ish" elapsed time)
SuspendingClock   stops while the device is asleep            ("awake" time)
your clock        e.g. a ManualClock for tests
```

## Core content

### The two system clocks (from the stdlib source)
| | `ContinuousClock` | `SuspendingClock` |
|---|---|---|
| Doc comment | "does not stop incrementing while the system is asleep" | "stops incrementing while the system is asleep" |
| Darwin source | `clock_gettime(CLOCK_MONOTONIC_RAW)` | `clock_gettime(CLOCK_UPTIME_RAW)` |
| Linux source | `CLOCK_BOOTTIME` | `CLOCK_MONOTONIC` |
| Use for | user-facing timeouts and deadlines ("in 30 s of real time") | measuring work, and things that should pause while the device sleeps |

(Sources: the doc comments in `ContinuousClock.swift` / `SuspendingClock.swift`, and `Clock.cpp`.)

**`Task.sleep(for:)` uses `.continuous` by default.** The 6.4 SDK declares `static func sleep<C: Clock>(for duration: C.Instant.Duration, tolerance: C.Instant.Duration? = nil, clock: C = .continuous) async throws`.

### Sleeping, deadlines, tolerance
<!-- check: lib -->
```swift
func poll() async throws {
    let clock = ContinuousClock()
    var next = clock.now
    while !Task.isCancelled {
        next = next.advanced(by: .seconds(5))                      // fixed-rate schedule, no drift
        try await Task.sleep(until: next, tolerance: .milliseconds(500), clock: clock)
        // … do the periodic work …
    }
}
```

- `sleep(until:)` with a deadline avoids the drift you get from repeated `sleep(for:)`.
- **`tolerance`** lets the system coalesce timers, which saves energy. Give it a value whenever exact timing doesn't matter.
- Every clock sleep is cancellation-aware: it throws `CancellationError` (verified in [2.3](../02-structured-concurrency/03-cancellation.md)).

### Measuring
`clock.measure { … }` returns a `Duration`. It has an async overload, which this guide's benchmarks use. To measure "time spent working", prefer `SuspendingClock`. To measure "time a user waited", prefer `ContinuousClock`.

### Clock epochs (SE-0473, implemented in Swift 6.3)
`ContinuousClock.systemEpoch` and `SuspendingClock.systemEpoch` expose the "zero" instant. Per the proposal, it's set at boot on Apple platforms, Linux and Windows. In the 6.4 SDK, both are `@_alwaysEmitIntoClient` and available from macOS 13 / iOS 16:

<!-- check: output "uptime (continuous): true" -->
```swift
let c = ContinuousClock(), s = SuspendingClock()
print("uptime (continuous):", c.now - c.systemEpoch > .zero,
      "awake time (suspending):", s.now - s.systemEpoch > .zero)
```

The epoch is **not** meaningful across machines or reboots. Don't serialize it.

### Timeouts in Swift 6.4: race against a sleep
There's no shipped timeout API in Swift 6.4. The pattern is a task group that races the operation against a sleep, and cancels the loser (verified):

<!-- check: output "slow: TimeoutError() after <1s: true" -->
```swift
struct TimeoutError: Error {}

func withTimeout<T: Sendable, C: Clock>(
    _ limit: C.Duration, clock: C = ContinuousClock(),
    _ op: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask { try await clock.sleep(for: limit); throw TimeoutError() }
        defer { group.cancelAll() }          // whichever finishes first, cancel the other
        return try await group.next()!
    }
}

let fast: String = try await withTimeout(.milliseconds(200)) { try await Task.sleep(for: .milliseconds(10)); return "fast" }
print(fast)

let start = ContinuousClock.now
do {
    _ = try await withTimeout(.milliseconds(50)) { try await Task.sleep(for: .seconds(5)); return "slow" }
} catch {
    print("slow:", error, "after <1s:", ContinuousClock.now - start < .seconds(1))
}
```

Caveats, which come straight from structured concurrency:
- **The group can't return until the timed-out operation actually stops.** If `op` ignores cancellation (for example, a blocking call), the timeout fires but `withTimeout` still waits. Timeouts only work for cancellation-aware work.
- `op` must be `@Sendable` and its result `Sendable`, because it runs in a child task.

### `withDeadline` (SE-0526): accepted, **not in the 6.4 SDK**
SE-0526, *withDeadline*, is "Accepted with modifications". On `main` it's implemented in `stdlib/public/Concurrency/Task+Deadline.swift` as `nonisolated(nonsending) func withDeadline<Return, Failure, C>(…)`, together with runtime support for "cancellation scopes" and cancellation reasons. **None of it is in the Swift 6.4 SDK** (verified: no `withDeadline` in the installed `_Concurrency.swiftinterface`). Use the race pattern above until it ships, and check the SDK of the toolchain you target.

### Custom clocks
Implementing `Clock` takes `now`, `minimumResolution`, and `sleep(until:tolerance:)`. [6.5](../06-apps/05-testing.md) has a complete, verified `ManualClock`. Write time-based APIs generically, `func debounce<C: Clock>(…, clock: C)`, or take `any Clock<Duration>`, so that tests can inject one.

## Pitfalls
- **`SuspendingClock` for user-facing timeouts.** If the device sleeps for an hour, a "30 s" timeout effectively lasts an hour plus 30 s.
- **`Date()` for measuring durations.** Wall-clock time can jump (NTP, or the user changing the time). Use a monotonic clock.
- **Timeouts around non-cancellable work.** They don't return early (see above).
- **`sleep(for:)` in a loop for periodic work** accumulates drift. Use deadlines.

## Under the hood
- Clock sleeps are implemented by the executor's timer support. On Darwin, the global executor schedules the delayed job with `dispatch_after` on the appropriate queue (`DispatchGlobalExecutor.cpp`, "Get a queue suitable for dispatch_after").
- The sleeping task is suspended. It holds no thread, so thousands of sleeping tasks cost only memory.

## Exercises
1. Change `withTimeout` to return `nil` on timeout, instead of throwing.
2. Write a `retry(times:backoff:clock:)` helper with exponential backoff that uses an injected clock. Test it with `ManualClock`.
3. A download should time out after 30 s of *real* time, even if the phone sleeps. Which clock do you use?

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
func withTimeoutOrNil<T: Sendable>(_ limit: Duration, _ op: @escaping @Sendable () async throws -> T) async rethrows -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await op() }
        group.addTask { try? await Task.sleep(for: limit); return nil }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

func retry<T: Sendable, C: Clock>(times: Int, initial: C.Duration, clock: C,
                                  _ op: () async throws -> T) async throws -> T where C.Duration == Duration {
    var delay = initial
    for _ in 1..<times {
        do { return try await op() } catch { try await clock.sleep(for: delay); delay *= 2 }
    }
    return try await op()
}
```
3. `ContinuousClock`. It keeps counting while the device sleeps.
</details>

## Check yourself
1. Which clock does `Task.sleep(for:)` use by default?
2. Why can't a timeout interrupt a blocking call?
3. Is `withDeadline` available in Swift 6.4?

<details><summary>Answers</summary>

1. `ContinuousClock` (`clock: C = .continuous`).
2. Cancellation is cooperative, and the task group must wait for the child to finish.
3. No. It's accepted, and implemented on `main`, but not in the 6.4 SDK.
</details>

## Further reading
- SE-0329 *Clock, Instant, and Duration*
- SE-0374 *Add sleep(for:) to Clock*
- SE-0473 *Clock Epochs*
- SE-0526 *withDeadline* (accepted)
