# 2.3 Cancellation

## Why it matters
A user leaves a screen, a search query changes, a timeout fires. Most started work eventually becomes unnecessary. Swift's cancellation is **cooperative**. Cancelling a task sets a flag and runs any registered handlers, and that's all it does. The task stops only if its code checks the flag, or calls something that does. Code that ignores cancellation wastes battery and bandwidth, and can update UI that's no longer on screen.

## Mental model

```
task.cancel()  ──▶  isCancelled = true (permanently)
                 ├─▶ propagates to all structured children (async let, group children)
                 ├─▶ runs registered onCancel handlers, immediately, on the canceller's thread
                 └─▶ does NOT stop any code; it's a request

The code then reacts at check points:
   Task.isCancelled / Task.checkCancellation() / try await Task.sleep(...) / cancellation-aware APIs
```

## Core content

### Checking for cancellation

<!-- check: lib -->
```swift
struct Item: Sendable {}
func process(_ chunk: [Int]) async -> Item { Item() }

func processAll(_ chunks: [[Int]]) async throws -> [Item] {
    var out: [Item] = []
    for chunk in chunks {
        try Task.checkCancellation()          // throws CancellationError if cancelled
        out.append(await process(chunk))
    }
    return out
}

func bestEffort(_ chunks: [[Int]]) async -> [Item] {
    var out: [Item] = []
    for chunk in chunks {
        if Task.isCancelled { break }         // non-throwing: return partial results
        out.append(await process(chunk))
    }
    return out
}
```

Pick based on your API contract: either throw `CancellationError`, or return partial or default results. Many system APIs throw when cancelled. `Task.sleep` throws `CancellationError` (verified: a cancelled 10-second sleep throws immediately). `URLSession` throws `URLError(.cancelled)` (verified, code `-999`).

### How cancellation propagates
- **Structured children** (`async let`, group children) are cancelled when their parent is cancelled.
- **Unstructured tasks** (`Task {}`, `Task.detached`) are **not** cancelled when the task that created them is cancelled. You have to keep their handles and cancel them yourself.
- Cancelling a task never cancels its *parent* or its siblings. When a child of a throwing group fails, the group cancels its *siblings* only as part of rethrowing ([2.2](02-async-let-and-task-groups.md)).
- In SwiftUI, the `.task {}` modifier cancels its task when the view disappears, and `.task(id:)` also cancels and restarts it when `id` changes ([6.1](../06-apps/01-swiftui.md)).

### `withTaskCancellationHandler`: reacting immediately
A cancellation check only happens when your code reaches one. If you're suspended waiting for a legacy callback, nobody is checking. A **cancellation handler** runs *at the moment* of cancellation. Two behaviors are verified with Swift 6.4:

1. If the task is **already cancelled** when you call `withTaskCancellationHandler`, `onCancel` runs **first**, immediately, and then the operation still runs.
2. Otherwise, `onCancel` runs on whichever thread calls `cancel()`, **concurrently** with the operation.

<!-- check: output "onCancel runs" -->
```swift
let t = Task {
    withUnsafeCurrentTask { $0?.cancel() }           // cancel ourselves
    await withTaskCancellationHandler {
        print("operation runs")
    } onCancel: {
        print("onCancel runs")                       // printed FIRST
    }
}
await t.value
```

In the 6.4 SDK, the signature is:

<!-- check: skip -->
```swift
nonisolated(nonsending) func withTaskCancellationHandler<Return, Failure>(
    operation: nonisolated(nonsending) () async throws(Failure) -> Return,
    onCancel handler: sending () -> Void
) async throws(Failure) -> Return
```

The `onCancel` closure is `sending`. (Before 6.4 it was `@Sendable`.) Either way, it can run concurrently with `operation`, so any state the two closures share needs synchronization.

### The hard case: a cancellable continuation
Here's how to bridge a legacy API that has its own `cancel()`. There's a race: `onCancel` may run *before* the continuation even exists, either because the task was already cancelled, or because cancellation arrives between the two steps. A small state machine behind a `Mutex` handles every interleaving:

<!-- check: output "pre-cancelled: failure(Swift.CancellationError())" -->
```swift
import Foundation
import Synchronization

// Stand-in for a legacy callback API. `@unchecked Sendable` is a claim that `cancel()`
// is safe to call from any thread; for a real API, that must come from its documentation.
final class LegacyTimer: @unchecked Sendable {
    private let item: DispatchWorkItem
    init(seconds: Double, fire: @escaping @Sendable () -> Void) {
        item = DispatchWorkItem(block: fire)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }
    func cancel() { item.cancel() }
}

func sleep(seconds: Double) async throws {
    enum State { case idle, waiting(CheckedContinuation<Void, any Error>, LegacyTimer), cancelled, done }
    let state = Mutex<State>(.idle)

    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            let timer = LegacyTimer(seconds: seconds) {
                let cont: CheckedContinuation<Void, any Error>? = state.withLock {
                    if case .waiting(let c, _) = $0 { $0 = .done; return c }
                    return nil
                }
                cont?.resume()
            }
            let alreadyCancelled = state.withLock { s -> Bool in
                if case .cancelled = s { return true }
                s = .waiting(c, timer)
                return false
            }
            if alreadyCancelled { timer.cancel(); c.resume(throwing: CancellationError()) }
        }
    } onCancel: {
        let toCancel: (CheckedContinuation<Void, any Error>, LegacyTimer)? = state.withLock {
            switch $0 {
            case .waiting(let c, let t): $0 = .done; return (c, t)
            case .idle: $0 = .cancelled; return nil      // the operation will see this
            default: return nil
            }
        }
        if let (c, t) = toCancel { t.cancel(); c.resume(throwing: CancellationError()) }
    }
}

let t1 = Task { try await sleep(seconds: 5) }
try await Task.sleep(for: .milliseconds(50))
t1.cancel()
print("cancelled mid-flight:", await t1.result)      // failure(CancellationError), in well under 1 s

print("normal:", await Task { try await sleep(seconds: 0.05) }.result)

let t3 = Task { withUnsafeCurrentTask { $0?.cancel() }; try await sleep(seconds: 5) }
print("pre-cancelled:", await t3.result)
```

All three paths are verified: cancelled mid-flight (it returned in under 1 s, not 5), completed normally, and already cancelled. Two things make this correct:
1. **Every resume happens after a state transition guarded by the lock**, so exactly one path can resume the continuation.
2. **The resume (and `timer.cancel()`) happens *after* `withLock` returns, never while holding the lock.** The stdlib documentation explains why: the cancellation handler "may be invoked while holding internal locks associated with the task", and resuming a continuation may take those same locks. So "if a cancellation handler must acquire a lock, other code should not cancel tasks or resume continuations while holding that lock". Breaking this rule can deadlock.

### Cancellation shields (Swift 6.4, SE-0504; requires OS 27+)
Sometimes code *must* run to completion even in a cancelled task, typically cleanup. `withTaskCancellationShield` hides the cancellation state from the code inside it:

<!-- check: output "child cancelled? unshielded: true shielded: false" -->
```swift
let t = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    print("before:", Task.isCancelled)                                     // true
    withTaskCancellationShield { print("inside:", Task.isCancelled) }      // false
    print("after:", Task.isCancelled)                                      // true

    async let a: Bool = Task.isCancelled
    let unshielded = await a
    let shielded = await withTaskCancellationShield {
        async let b: Bool = Task.isCancelled
        return await b
    }
    print("child cancelled? unshielded:", unshielded, "shielded:", shielded)
}
await t.value
```

Semantics, verified with the program above and from the proposal:
- Inside the shield, `Task.isCancelled` is `false` and `Task.checkCancellation()` doesn't throw.
- **Children created inside the shield aren't cancelled** by the outer cancellation (verified: `shielded: false`).
- Cancellation handlers registered inside the shield don't fire.
- The shield doesn't *undo* cancellation. After the shield, the task is still cancelled. The *instance* property `task.isCancelled`, read from outside the task, always reports the real state.
- `Task.hasActiveCancellationShield` tells you whether you're currently inside a shield.
- There's a synchronous overload and an async one. Their parameter label is `operation:` in the 6.4 SDK. (The proposal shows `_`, but with a trailing closure it makes no difference.)
- Availability is `@available(anyAppleOS 27.0, *)`, because it needs runtime support.

The pattern it was designed for, combined with async `defer` ([1.3](../01-async-await/03-errors-typed-throws-defer.md)):

<!-- check: lib -->
```swift
struct Connection: Sendable {
    func close() async {}
}

func withConnection<T>(_ conn: Connection, _ body: (Connection) async throws -> T) async rethrows -> T {
    defer {
        await withTaskCancellationShield {
            await conn.close()          // runs to completion even if the task was cancelled
        }
    }
    return try await body(conn)
}
```

Before 6.4 (or on older OSes), the workaround was `await Task { await conn.close() }.value`. It escapes the cancelled tree by creating a new unstructured task.

## Pitfalls & compiler errors
- **Swallowing `CancellationError` and carrying on as if nothing happened.** If your API is cancellable, propagate the error, or return a clearly partial result.
- **Ignoring cancellation in CPU-bound loops.** A tight loop with no `await` never reaches a check point. Add `try Task.checkCancellation()` (or `await Task.yield()`) every N iterations.
- **Not resuming the continuation from `onCancel`.** You have to resume it exactly once, on whichever path wins (see the state machine above).
- **Assuming that `onCancel` runs on your actor.** It runs synchronously inside `task.cancel()`, on the thread of whoever cancels.
- **Expecting `Task {}` children to be cancelled when their creator is cancelled.** They aren't. Keep the handles and cancel them, or use structured concurrency.

## Under the hood
All from `stdlib/public/Concurrency/TaskStatus.cpp` and `TaskCancellation.swift`:
- Cancellation sets a bit in the task's atomic `ActiveTaskStatus`. `Task.isCancelled` reads it.
- `withTaskCancellationHandler` unconditionally adds a `CancellationNotification` *status record* to the task. If the task is already cancelled, the handler runs right away, and the record is removed in a `defer` when the operation finishes.
- Cancelling a task walks its status records (`performCancellationAction`): `ChildTask` records recursively cancel the children, `TaskGroup` records cancel the group ("so that child tasks added later start out cancelled"), and `CancellationNotification` records run the handlers.
- A shield pushes a `TaskCancellationShieldRecord` and sets a `HasActiveTaskCancellationShield` status bit. The observed cancellation state is "cancelled and no active shield", and the record walk stops at the shield. This needed runtime changes, which is why shields require OS 27.

## Exercises
1. Write `func search(_ query: String) async throws -> [String]` that sleeps 300 ms ("debounce") and then returns results, and show that cancelling it during the sleep throws `CancellationError`.
2. A loop calls a synchronous, CPU-heavy `crunch(i)` 1,000,000 times. Make it cancellable without slowing it down much.
3. Explain why the cancellable `sleep(seconds:)` above needs the `.idle → .cancelled` transition.

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
func search(_ query: String) async throws -> [String] {
    try await Task.sleep(for: .milliseconds(300))      // throws CancellationError if cancelled
    return [query]
}

func crunch(_ i: Int) -> Int { i &* 31 }

func crunchAll() async throws -> Int {
    var acc = 0
    for i in 0..<1_000_000 {
        if i % 10_000 == 0 { try Task.checkCancellation() }   // amortize the check
        acc &+= crunch(i)
    }
    return acc
}
```
3. `onCancel` can run before the continuation has been stored: either because the task was already cancelled (then `onCancel` runs before the operation), or because cancellation arrives between `withCheckedThrowingContinuation` starting and `state` being set. Without the `.cancelled` state, that cancellation would be lost, and the operation would wait for the full timer.
</details>

## Check yourself
1. Does `task.cancel()` stop the task's code?
2. Is a `Task {}` created inside a cancelled task cancelled too?
3. Inside `withTaskCancellationShield`, what does `Task.isCancelled` return? What does `someTaskHandle.isCancelled` return for the current task, read from outside?

<details><summary>Answers</summary>

1. No. It sets a flag and runs the handlers. The code has to cooperate.
2. No. Unstructured tasks don't inherit cancellation.
3. `false` inside the shield. The instance property, read from outside, returns the real state: `true`.
</details>

## Further reading
- SE-0304 *Structured concurrency*, section "Cancellation"
- SE-0504 *Task Cancellation Shields*
- SE-0493 *Support `async` calls in `defer` bodies*
