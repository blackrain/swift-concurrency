# 7.6 Patterns and anti-patterns: an expert's review checklist

## Why it matters
This chapter condenses the guide into a code-review checklist. Every item links to the chapter where its behavior was **verified**, either with the compiler or with a measured run.

## Mental model
For every async boundary in a PR, ask:
1. **Where does this run?** (isolation)
2. **What crosses?** (Sendable / sending)
3. **What happens at each `await`?** (reentrancy, cancellation)
4. **Who owns this task?** (structure, lifetime)

## Core content

### Anti-patterns → fixes

| # | Anti-pattern | Why it's wrong (verified in) | Fix |
|---|---|---|---|
| 1 | `Task {}` inside async code for concurrency | it loses cancellation and error propagation, and isn't awaited ([2.1](../02-structured-concurrency/01-tasks.md)) | `async let` / a task group |
| 2 | `Task.detached` "to go to the background" | it drops priority and task-locals; the captures must be `sending` ([2.1](../02-structured-concurrency/01-tasks.md)) | a `@concurrent` function |
| 3 | blocking waits in async code (semaphores, `DispatchGroup.wait`) | starves the cooperative pool; deadlocked in [0.2](../00-foundations/02-races-deadlocks-inversion.md), and immediately with `POOL_STRICT=1` ([7.1](01-runtime.md)) | continuations, `await` |
| 4 | check-then-act across `await` inside an actor | reentrancy: `true true -60`, 10 downloads instead of 1 ([3.1](../03-isolation-and-actors/01-actors.md)) | mutate before suspending; in-flight `Task`s |
| 5 | heavy work in `@MainActor` code, or in plain `async` functions under `NonisolatedNonsendingByDefault` | runs on the main thread ([1.1](../01-async-await/01-async-functions.md), [3.4](../03-isolation-and-actors/04-approachable-concurrency.md)) | `@concurrent` |
| 6 | `@unchecked Sendable` / `nonisolated(unsafe)` as an error fix | hides real races (TSan found `Swift access race`, [0.2](../00-foundations/02-races-deadlocks-inversion.md)) | actor / `Mutex` / `Sendable` value types |
| 7 | fire-and-forget throwing `Task` | errors vanish; 6.4 warns `[#NoUseUnstructuredThrowingTask]` ([1.3](../01-async-await/03-errors-typed-throws-defer.md)) | handle the error inside, or keep the handle |
| 8 | relying on actor call order across priorities | `HIGH` ran before earlier `low` calls ([7.3](03-actors-and-escalation.md)) | a single-consumer stream (below) |
| 9 | fine-grained actor chatter (`await a.x`, `await a.y`, …) | each main-actor round trip ~2.7 µs ([7.4](04-performance-debugging.md)) | coarse intent methods, snapshots |
| 10 | a continuation not resumed on every path | a hang, plus a `SWIFT TASK CONTINUATION MISUSE … leaked` log ([1.2](../01-async-await/02-bridging-continuations.md)) | a state machine; `withContinuation` (OS 27) |
| 11 | `AsyncStream` without `onTermination`; two consumers of an `AsyncThrowingStream` | leaks; `Fatal error: attempt to await next() on more than one task` ([5.2](../05-async-sequences/02-asyncstream.md)) | always set `onTermination`; one consumer, or `share()` |
| 12 | `assumeIsolated` to silence the compiler | traps when the guess is wrong ([3.5](../03-isolation-and-actors/05-nonisolated-and-escape-hatches.md)) | fix the caller's isolation |
| 13 | `onAppear { Task { … } }` | the work outlives the view ([6.1](../06-apps/01-swiftui.md)) | `.task` / `.task(id:)` |
| 14 | a timeout around non-cancellable work | the timeout can't return early ([7.5](05-clocks-and-time.md)) | make the work cancellation-aware |
| 15 | `Codable` models in a MainActor-default module, decoded in the background | `[#IsolatedConformances]` error ([3.4](../03-isolation-and-actors/04-approachable-concurrency.md)) | `nonisolated struct` |

## Patterns worth memorizing

### 1. Reserve before suspending (actors)
Mutate state synchronously, then await ([3.1](../03-isolation-and-actors/01-actors.md), Bank solution).

### 2. Coalesce in-flight work
Store a `Task` in the actor before the first `await`, and let later callers await it ([3.1](../03-isolation-and-actors/01-actors.md): 1 download for 10 callers).

### 3. Ordered processing regardless of caller priority (verified)
<!-- check: output "[\"low0\", \"low1\", \"HIGH\", \"low2\"]" -->
```swift
final class CommandProcessor: Sendable {
    private let continuation: AsyncStream<String>.Continuation
    private let worker: Task<[String], Never>

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        self.continuation = continuation
        worker = Task {
            var applied: [String] = []
            for await command in stream { applied.append(command) }   // one consumer → strict order
            return applied
        }
    }

    func submit(_ command: String) { continuation.yield(command) }   // synchronous: order fixed at the call site
    func finish() async -> [String] { continuation.finish(); return await worker.value }
}

let p = CommandProcessor()
p.submit("low0")
await Task(priority: .low) { p.submit("low1") }.value
await Task(priority: .high) { p.submit("HIGH") }.value
p.submit("low2")
print(await p.finish())
```

The output is `["low0", "low1", "HIGH", "low2"]`: submission order, unlike the actor-mailbox experiment in [7.3](03-actors-and-escalation.md).

### 4. Snapshot boundaries
Services return `Sendable` value types. Models own the mutable UI state ([6.2](../06-apps/02-architecture.md)).

### 5. Bounded fan-out
A sliding-window task group caps how many children run at once ([2.2](../02-structured-concurrency/02-async-let-and-task-groups.md)).

### 6. Cancellable bridge
A continuation plus `withTaskCancellationHandler`, with a `Mutex` state machine. Resume outside the lock ([2.3](../02-structured-concurrency/03-cancellation.md)).

### 7. Context propagation
`@TaskLocal` for request IDs and tracing. It's inherited by children and `Task {}`, but not by `Task.detached` ([2.1](../02-structured-concurrency/01-tasks.md)).

### 8. Testable time
Inject a `Clock`, and advance a `ManualClock` in tests ([6.5](../06-apps/05-testing.md)).

### 9. Guaranteed cleanup (Swift 6.4, OS 27)
`defer { await withTaskCancellationShield { await resource.close() } }` ([2.3](../02-structured-concurrency/03-cancellation.md)).

## Pitfalls
Checklists catch known shapes. They don't replace the four questions in the mental model. New APIs (shields, `withContinuation`, isolated conformances) shift what the best fix is, so re-check this list against each Swift release.

## Under the hood
Each row in the anti-pattern table traces back to a mechanism covered in Part 7: the cooperative pool's fixed width (3), suspension handing the actor to the next job (4), the enqueue path for main-actor hops (9), and the actor's priority buckets (8).

## Exercises
Review this code against the checklist. Find at least six problems:

<!-- check: skip -->
```swift
@MainActor final class PhotoModel {
    var photos: [Photo] = []
    let cache = ImageCache()                       // an actor
    func load() {
        Task.detached {
            let sem = DispatchSemaphore(value: 0)
            var result: [Photo] = []
            api.fetch { result = $0; sem.signal() }
            sem.wait()
            for p in result { await self.cache.store(p) }
            self.photos = result
        }
    }
}
```

<details><summary>Answer</summary>

1. `Task.detached` drops priority and context. Use `Task {}`, or better, make `load()` `async` and call it from `.task`.
2. Blocking a cooperative thread with a semaphore. Bridge `api.fetch` with a continuation.
3. `result` is a captured `var` mutated from a callback that may run concurrently (a data race).
4. One actor hop per photo (`cache.store` in a loop). Add a batch API, `store(contentsOf:)`.
5. `self.photos = result` from a detached (nonisolated) context won't compile. It needs `await MainActor.run`, or the code should run on the main actor in the first place.
6. Nobody owns the task: no handle, no cancellation, and errors (if any) are lost.
7. If `api.fetch` never calls back, the task hangs forever, still holding a pool thread.
</details>

## Check yourself
Without looking back: name the four review questions, and give one verified number from this guide that shows why actor-hop granularity matters.

<details><summary>Answer</summary>

Where does it run? What crosses? What happens at each `await`? Who owns the task? For the number: a round trip from the main actor to an actor cost ~2.7 µs, versus ~55 ns from nonisolated code.
</details>

## Further reading
- Swift Forums, *Using Swift* category (most concurrency questions are discussed there): https://forums.swift.org/c/swift-users
- The swift-evolution proposals referenced throughout ([resources](../resources.md))
