# 1.2 Bridging callback APIs with continuations

## Why it matters
Completion handlers, delegates and C callbacks won't disappear. A **continuation** turns "call me back later" into "`await` the result". It's the most common place where async code goes subtly wrong, because the compiler can't see inside the callback API you're wrapping.

## Mental model

```
await withCheckedContinuation { c in      ① body runs synchronously, right away
    legacyAPI { value in                  ② body returns → the task suspends
        c.resume(returning: value)        ③ some time later, on some thread: resume
    }                                     ④ the awaiting task is scheduled again
}
```

**The contract:** every continuation must be resumed **exactly once**. Zero times means the awaiting task hangs forever. Twice is a bug: undefined behavior with the unsafe variant, a trap with the checked one, and a compile error with the new noncopyable one.

## Core content

### The four flavors (Swift 6.4)

| API | Failure | Double resume | Missing resume | Availability |
|---|---|---|---|---|
| `withUnsafeContinuation` / `withUnsafeThrowingContinuation` | `Never` / `any Error` | undefined behavior | silent hang | all |
| `withCheckedContinuation` / `withCheckedThrowingContinuation` | `Never` / `any Error`, or a **typed** `E` | runtime trap | runtime **warning** (logged), then a hang | all (typed overload is `@_alwaysEmitIntoClient`) |
| `withContinuation(of:)` / `withContinuation(of:throwing:)` (SE-0528) | `Never` / any `Failure` | **compile error** | runtime trap | **iOS/macOS 27+** (`@available(anyAppleOS 27.0, *)`) |

Use `withCheckedContinuation` by default. Use `withContinuation` when you can require OS 27. Use the unsafe variants only after profiling shows the checking matters, and once the code is well tested.

### Wrapping a completion handler

<!-- check: output "4 resumed with 7" -->
```swift
import Foundation

func legacy(_ done: @escaping @Sendable (Int) -> Void) {
    DispatchQueue.global().async { done(7) }
}

func bridged() async -> Int {
    print("1 before")
    let v = await withCheckedContinuation { continuation in
        print("2 body runs synchronously")
        legacy { continuation.resume(returning: $0) }
        print("3 body returned")
    }
    print("4 resumed with", v)
    return v
}

_ = await bridged()
```

This prints 1, 2, 3, 4 in that order (verified). The body runs **immediately and synchronously** on the caller's isolation. The task suspends only after the body returns.

### Throwing, including typed throws
The `Result`-style resume methods match the shapes of callback APIs:

<!-- check: lib -->
```swift
import Foundation

enum NetError: Error { case offline, badStatus(Int) }

func legacyFetch(_ done: @escaping @Sendable (Data?, NetError?) -> Void) {
    done(nil, .offline)
}

// Typed throws: the 6.4 SDK has `withCheckedThrowingContinuation<T, E>` returning `throws(E)`.
func fetch() async throws(NetError) -> Data {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, NetError>) in
        legacyFetch { data, error in
            if let error { c.resume(throwing: error) }
            else { c.resume(returning: data ?? Data()) }
        }
    }
}

// Untyped, using `resume(with:)` for a Result-shaped callback:
func legacyResult(_ done: @escaping @Sendable (Result<Int, any Error>) -> Void) { done(.success(1)) }

func value() async throws -> Int {
    try await withCheckedThrowingContinuation { c in legacyResult { c.resume(with: $0) } }
}
```

### Wrapping a delegate: storing the continuation
A delegate API delivers its result later, through a different method, so you store the continuation:

<!-- check: output "here" -->
```swift
import Foundation

@MainActor
final class LocationBridge {
    private var pending: CheckedContinuation<String, any Error>?

    func request() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            pending = c
            startLegacyRequest()          // the delegate callback arrives later
        }
    }

    // Delegate callback (on the main actor in this example):
    func didDeliver(_ value: String) {
        pending?.resume(returning: value)
        pending = nil                     // ← critical: never resume the same continuation twice
    }

    private func startLegacyRequest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            MainActor.assumeIsolated { self.didDeliver("here") }   // assumeIsolated is valid here: this closure is on the main queue
        }
    }
}

print(try await LocationBridge().request())
```

What happens if `request()` is called again while a request is pending? Your code has to decide: reject the call, queue it, or resume the old continuation with an error before storing the new one. Overwriting `pending` leaks the first continuation, and the first caller hangs.

For APIs that deliver **many** values (delegates with repeated callbacks, notifications), use `AsyncStream`, not a continuation ([5.2](../05-async-sequences/02-asyncstream.md)).

### The noncopyable `Continuation` (Swift 6.4, OS 27+)
SE-0528 makes double-resume a compile-time error:

<!-- check: lib -->
<!-- check: error "'c' consumed more than once" -->
```swift
func g() async -> Int {
    await withContinuation(of: Int.self) { c in
        c.resume(returning: 1)
        c.resume(returning: 2)   // ❌ error: 'c' consumed more than once
    }
}
```

If you drop it without resuming, the program traps: `Fatal error: Continuation was deinitialized without being resumed.` (That's the actual 6.4 runtime message. The proposal text words it differently.) Because the type is `~Copyable`, it **can't be captured by an escaping closure**. Most completion-handler APIs take escaping closures, so in practice you convert it first:

<!-- check: lib -->
```swift
func legacy(_ done: @escaping @Sendable (Int) -> Void) { done(1) }

func bridged() async -> Int {
    await withContinuation(of: Int.self) { c in
        let checked = CheckedContinuation(c)          // convert to a copyable, checked continuation
        legacy { checked.resume(returning: $0) }
    }
}
```

So `withContinuation` mainly pays off when you hand the continuation directly to something that **consumes** it, such as storing it in a noncopyable or `Optional` property and consuming it later.

### Free bridging for Objective-C APIs
The Objective-C importer automatically creates an `async` version of a method (SE-0297) when all of the following hold:
- the method itself returns `void`,
- its completion-handler block returns `void`,
- the handler is identified either by an explicit `swift_async` attribute or by naming heuristics (for example, a selector that ends in `WithCompletionHandler:`).

Methods that return something, like `-[NSURLSession dataTaskWithURL:completionHandler:]` (which returns the task), are **not** imported as async. Here's one that is: `-getNotificationSettingsWithCompletionHandler:` becomes `notificationSettings() async`:

<!-- check: lib -->
```swift
import UserNotifications

func authorizationStatus() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
}
```

Before you write a continuation for an Apple API, check whether an async version already exists.

## Pitfalls & compiler errors
These are the runtime messages from Swift 6.4, verified:
- Missing resume with `CheckedContinuation`: `SWIFT TASK CONTINUATION MISUSE: leak() leaked its continuation without resuming it. This may cause tasks waiting on it to remain suspended forever.` This is a **log message, not a crash**. The program keeps running, and the task stays suspended.
- Double resume with `CheckedContinuation`: `Fatal error: SWIFT TASK CONTINUATION MISUSE: twice() tried to resume its continuation more than once, returning 2!`
- **Every path must resume.** Watch out for `guard … else { return }` inside callbacks, and for callback APIs that sometimes never call back (for example, on deallocation).
- **Continuations ignore cancellation.** If the task is cancelled while it's suspended on a continuation, nothing happens unless you set that up. Combine the continuation with `withTaskCancellationHandler` to cancel the underlying operation and resume with `CancellationError()` ([2.3](../02-structured-concurrency/03-cancellation.md)).
- **The resumed value is `sending`.** `resume(returning:)` takes `sending T`, so you can't resume with a non-`Sendable` value that the callback's context keeps using afterwards. The region checker rejects that ([4.2](../04-sendable-and-safety/02-region-isolation.md)).

## Under the hood
- `CheckedContinuation` holds a heap-allocated `CheckedContinuationCanary` (`stdlib/public/Concurrency/CheckedContinuation.swift`). The canary owns the underlying `UnsafeContinuation`, and `resume` atomically *takes* it out. A second `resume` finds it empty and calls `fatalError`. If the canary is deinitialized while it still holds the continuation, its `deinit` logs the "leaked its continuation" message. That's why the check costs an allocation plus atomic operations. The new `Continuation` replaces that runtime bookkeeping with move-only ownership, and uses `discard self` so that the success path doesn't trigger its trapping `deinit`.
- `UnsafeContinuation` is essentially a pointer to the suspended task. Resuming it schedules the task back onto its executor.
- In the 6.4 SDK, `withCheckedContinuation`, `withCheckedThrowingContinuation` and `withContinuation` are declared `nonisolated(nonsending)`. (The `isolation:`-parameter overloads from Swift 6.0 still exist for ABI.) The body runs on the caller's actor, which is why a `@MainActor` class can assign `pending = c` inside it without an `await`.

## Exercises
1. Wrap `func legacyTimer(seconds: Double, _ fire: @escaping @Sendable () -> Void)` as `func sleep(seconds: Double) async`.
2. Write a bridge for a delegate API that rejects a second concurrent `request()` by throwing `BridgeError.busy`.
3. Make your `sleep(seconds:)` from exercise 1 respond to cancellation, assuming the legacy timer returns a token with `cancel()`. (Come back to this after [2.3](../02-structured-concurrency/03-cancellation.md).)

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
import Foundation

func legacyTimer(seconds: Double, _ fire: @escaping @Sendable () -> Void) {
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: fire)
}

func sleep(seconds: Double) async {
    await withCheckedContinuation { c in
        legacyTimer(seconds: seconds) { c.resume() }
    }
}

enum BridgeError: Error { case busy }

@MainActor
final class Bridge {
    private var pending: CheckedContinuation<String, any Error>?

    func request() async throws -> String {
        guard pending == nil else { throw BridgeError.busy }
        return try await withCheckedThrowingContinuation { c in
            pending = c
            // start the legacy request here
        }
    }

    func deliver(_ value: String) {
        pending?.resume(returning: value)
        pending = nil
    }
}
```
</details>

## Check yourself
1. When does the body closure of `withCheckedContinuation` run?
2. What do you see when a `CheckedContinuation` is never resumed? Does the program crash?
3. Why can't you capture a `Continuation` (SE-0528) in an escaping completion handler?

<details><summary>Answers</summary>

1. Immediately and synchronously, before the calling task suspends.
2. A `SWIFT TASK CONTINUATION MISUSE: … leaked its continuation` log message when the continuation is destroyed. The program doesn't crash. The awaiting task stays suspended forever.
3. It's `~Copyable`, and capturing it in an escaping closure would require the compiler to copy it or let the closure own it in a way it can't prove happens exactly once.
</details>

## Further reading
- SE-0300 *Continuations for interfacing async tasks with synchronous code*
- SE-0528 *`Continuation`: Safe and Performant Async Continuations*
- SE-0297 *Concurrency Interoperability with Objective-C*
