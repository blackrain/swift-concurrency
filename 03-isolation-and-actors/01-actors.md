# 3.1 Actors: isolation and reentrancy

## Why it matters
An actor is a reference type that **protects its mutable state** by letting only one piece of code access it at a time. It replaces the "class + serial queue/lock" pattern from [0.1](../00-foundations/01-threads-queues-parallelism.md), and the compiler checks it. Actors have one surprising property, **reentrancy**, and it causes most actor bugs in real code.

## Mental model

```
            ┌──────────── actor Bank ────────────┐
callers ──▶ │ mailbox: [job, job, job]           │   one job runs at a time on the actor's
            │ state: balance                     │   serial executor
            │ runs a job until it finishes OR    │
            │ reaches an `await` that suspends ──┼──▶ the actor is now FREE: the next job may run
            └────────────────────────────────────┘
```

**An actor guarantees mutual exclusion between suspension points, not for the entire duration of a method call.**

## Core content

### Isolation: what the compiler enforces

<!-- check: lib -->
```swift
actor Store {
    private(set) var items: [Int] = []
    func add(_ i: Int) { items.append(i) }      // isolated: runs on the actor
    func count() -> Int { items.count }
}

func client(store: Store) async {
    await store.add(1)                 // cross-actor call: needs `await` (the actor may be busy)
    let n = await store.count()
    let snapshot = await store.items   // reading a property from outside: also `await`
    print(n, snapshot)
}
```

Inside the actor, its members are accessed synchronously. From outside:
- **Every access needs `await`.** The call is a potential suspension point, because the actor may be busy running something else.
- **Properties can't be mutated from outside, even with `await`.** `await store.items.append(1)` fails with `actor-isolated property 'items' can not be mutated from a nonisolated context`. Mutations have to go through actor methods. That's a deliberate design choice, because a mutation from outside would be a read-modify-write split by an await.
- Forgetting `await` on a cross-actor call gives `actor-isolated instance method 'add' cannot be called from outside of the actor` (wording verified with 6.4).
- **Values that cross the boundary must be `Sendable`, or `sending`** ([Part 4](../04-sendable-and-safety/)).

### Reentrancy: the critical part
When an actor method hits an `await` that actually suspends, the actor becomes free. **Other calls can run and change its state before the method resumes.** The bank example from [0.2](../00-foundations/02-races-deadlocks-inversion.md) printed `true true -60`, because two withdrawals of 80 both passed the balance check before either one deducted.

Here's a more realistic version: a cache that downloads the same image several times.

<!-- check: output "downloads for 10 concurrent requests: 10" -->
```swift
import Synchronization

let fetchCount = Atomic<Int>(0)

@concurrent func download(_ key: String) async throws -> String {
    fetchCount.add(1, ordering: .relaxed)
    try await Task.sleep(for: .milliseconds(50))
    return "image:\(key)"
}

actor NaiveCache {
    private var images: [String: String] = [:]
    func image(for key: String) async throws -> String {
        if let image = images[key] { return image }      // check…
        let image = try await download(key)              // …suspend: 9 other callers pass the check too…
        images[key] = image                              // …act
        return image
    }
}

let cache = NaiveCache()
try await withThrowingTaskGroup(of: String.self) { group in
    for _ in 0..<10 { group.addTask { try await cache.image(for: "cat") } }
    for try await _ in group {}
}
print("downloads for 10 concurrent requests:", fetchCount.load(ordering: .relaxed))
```

The result is **10 downloads** (verified). The fix is the most important actor pattern there is: **record the in-flight work before suspending.**

<!-- check: output "downloads for 10 concurrent requests: 1" -->
```swift
import Synchronization

let fetchCount = Atomic<Int>(0)

@concurrent func download(_ key: String) async throws -> String {
    fetchCount.add(1, ordering: .relaxed)
    try await Task.sleep(for: .milliseconds(50))
    return "image:\(key)"
}

actor ImageCache {
    private enum Entry { case inFlight(Task<String, any Error>), ready(String) }
    private var entries: [String: Entry] = [:]

    func image(for key: String) async throws -> String {
        if let entry = entries[key] {
            switch entry {
            case .ready(let image):     return image
            case .inFlight(let task):   return try await task.value   // join the existing download
            }
        }
        let task = Task { try await download(key) }
        entries[key] = .inFlight(task)            // recorded BEFORE the first suspension
        do {
            let image = try await task.value
            entries[key] = .ready(image)
            return image
        } catch {
            entries[key] = nil                    // let a later call retry
            throw error
        }
    }
}

let cache = ImageCache()
try await withThrowingTaskGroup(of: String.self) { group in
    for _ in 0..<10 { group.addTask { try await cache.image(for: "cat") } }
    for try await _ in group {}
}
print("downloads for 10 concurrent requests:", fetchCount.load(ordering: .relaxed))
```

The result is **1 download** (verified).

**Rules for writing reentrancy-safe actors:**
1. **Mutate state synchronously.** Do the check and the update with no `await` between them.
2. **Re-validate after every `await`.** Treat everything you read before it as potentially stale.
3. **Record intent before suspending.** Use in-flight markers, reservations, or a version counter.
4. **Keep actor methods small and synchronous where you can.** Do the slow async work outside the actor, then call a sync method to commit the result.

Why not make actors non-reentrant? Non-reentrant actors deadlock when two actors call each other, or when an actor calls back into itself through an async chain, and they make priority inversion worse. SE-0306 chose reentrancy on purpose, and discusses the alternative under *Actor reentrancy*.

### Initializers and deinitializers
Verified with Swift 6.4 (the rules come from SE-0327 and SE-0371):

<!-- check: lib -->
<!-- check: error "call to actor-isolated instance method 'bump()' in a synchronous nonisolated context" -->
```swift
actor Counter {
    var n: Int
    init(start: Int) {
        n = start
        bump()                  // ❌ a synchronous actor init is nonisolated
    }
    init(asyncStart: Int) async {
        n = asyncStart
        bump()                  // ✅ an async init is isolated to the actor once all stored properties are set
    }
    func bump() { n += 1 }
}
```

- **Synchronous `init`**: nonisolated. You can initialize the stored properties, but you can't call isolated methods.
- **`async init`**: isolated to the actor once `self` is fully initialized.
- **`deinit`** is nonisolated by default. You can read and write stored properties there, but calling an isolated method fails with `call to … isolated instance method '…' in a synchronous nonisolated context [#ActorIsolatedCall]`.
- **`isolated deinit`** (Swift 6.2, SE-0371) runs the deinit on the actor's executor. If the last reference is released somewhere else, the deinit hops to the actor. I verified that a `@MainActor` class's `isolated deinit` ran on the main thread even though the last reference was dropped in a detached task.
  - **Availability, verified by compiling for older targets:** for actors and custom global actors it requires **macOS 15.4 / iOS 18.4** or newer (`error: isolated deinit is only available in macOS 15.4.0 or newer`). For **`@MainActor`** it back-deploys, because the compiler embeds a `swift_task_deinitOnExecutorMainActorBackDeploy` shim in your binary.

<!-- check: lib -->
```swift
@MainActor
final class PlayerController {
    private var displayLink: Int? = 1
    func stopDisplayLink() { displayLink = nil }

    isolated deinit {
        stopDisplayLink()       // ✅ allowed: the deinit runs on the main actor
    }
}
```

### `nonisolated` members
Members that don't touch mutable state can opt out of isolation, so callers don't need `await`:

<!-- check: lib -->
```swift
actor Account {
    let id: String              // `let` of a Sendable type: readable without await from the same module
    var balance = 0
    init(id: String) { self.id = id }

    nonisolated var label: String { "Account \(id)" }   // OK: only uses immutable state
}
```

SE-0306 allows synchronous access to an actor's `let` properties only from **within the same module**. From other modules, access must be `await`ed, so that a library can later turn the `let` into a `var` without breaking its clients. If you want synchronous access across modules, mark the member `nonisolated` explicitly.

A `nonisolated` member that tries to read `var` state is rejected with `actor-isolated property 'balance' can not be referenced from a nonisolated context`.

### Actor or `Mutex`?
| Use an actor when… | Use `Mutex` ([4.3](../04-sendable-and-safety/03-unchecked-mutex-atomics.md)) when… |
|---|---|
| the operations are naturally async (they await I/O) | the critical sections are tiny and synchronous |
| you want callers to `await` (backpressure, fairness) | callers are synchronous and can't `await` |
| the state is large and the operations are many | it's just a counter, a flag or a small cache, on a hot path |

## Pitfalls & compiler errors
| Diagnostic | Fix |
|---|---|
| `actor-isolated instance method '…' cannot be called from outside of the actor` | add `await` |
| `actor-isolated property '…' can not be mutated from a nonisolated context` | add a mutating actor method |
| `call to actor-isolated instance method '…' in a synchronous nonisolated context` | make the caller async/isolated, or (in an init) use an `async init` |
| `isolated deinit is only available in macOS 15.4.0 or newer` | raise the deployment target, or use `@MainActor` (which back-deploys) |

- **Long synchronous work inside an actor** blocks every other caller of that actor. Actors aren't for CPU parallelism. A single actor runs one job at a time.
- **Many tiny `await actor.x` calls in a loop** cost a hop each and can interleave with other callers. Batch them into one actor method.

## Under the hood
- Every actor has a **serial executor**. Default actors use a runtime-provided executor that's integrated with the cooperative pool. A job for a free actor can run right away on the current thread ("switching"), without a thread hop. Otherwise it's enqueued.
- An actor's state includes an atomic status word (`ActiveActorStatus` in `Actor.cpp`) that tracks idle, scheduled and running states, the highest priority of pending jobs, and on Darwin the identity of the thread running it, which is used for priority escalation.
- Reentrancy falls out of the design: a suspended actor method is just a suspended task. While it's suspended, it isn't running on the actor, so the actor is free.
- See [7.3](../07-internals/03-actors-and-escalation.md) for the full state machine.

## Exercises
1. Fix the `Bank` from 0.2 using the "reserve before suspending" rule. Then fix it again by moving the slow work outside the actor.
2. Extend `ImageCache` with `func cancel(key:)`, which cancels an in-flight download. What happens to the callers waiting on `task.value`?
3. Design an actor `RateLimiter` with `func acquire() async`, which allows at most N acquisitions per second. Watch out for reentrancy.

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
actor Bank {
    var balance = 100
    func reserve(_ amount: Int) -> Bool {           // synchronous: atomic on the actor
        guard balance >= amount else { return false }
        balance -= amount
        return true
    }
    func refund(_ amount: Int) { balance += amount }
}

func withdraw(_ amount: Int, from bank: Bank) async -> Bool {
    guard await bank.reserve(amount) else { return false }
    do {
        try await Task.sleep(for: .milliseconds(50))       // slow work outside the actor
        return true
    } catch {
        await bank.refund(amount)                           // compensate if cancelled
        return false
    }
}

actor RateLimiter {
    private let perSecond: Int
    private var timestamps: [ContinuousClock.Instant] = []
    init(perSecond: Int) { self.perSecond = perSecond }

    func acquire() async throws {
        while true {
            let now = ContinuousClock.now
            timestamps.removeAll { now - $0 > .seconds(1) }
            if timestamps.count < perSecond {
                timestamps.append(now)                       // commit before any suspension
                return
            }
            let wait = timestamps[0] + .seconds(1) - now
            try await Task.sleep(for: wait)                  // after waking, re-check: other callers may have taken the slot
        }
    }
}
```
2. Cancelling the stored `Task` cancels `download`. `Task.sleep` throws `CancellationError`, so every caller awaiting `task.value` receives that error. Remove the entry so that later calls can retry.
</details>

## Check yourself
1. Does an actor run one method call from start to finish without interruption?
2. Why can't you write `await actor.items.append(x)`?
3. Is `isolated deinit` available on iOS 17 for an `actor`? For a `@MainActor` class?

<details><summary>Answers</summary>

1. No. Only the stretches between suspension points are exclusive.
2. Mutating actor state from outside is forbidden. It would be a read-modify-write split across an isolation boundary. Use an actor method.
3. Not for an `actor`: it needs iOS 18.4. For a `@MainActor` class, yes: it back-deploys through a compiler-embedded shim (verified with the 6.4 toolchain).
</details>

## Further reading
- SE-0306 *Actors* (read the "Actor reentrancy" section)
- SE-0327 *On Actors and Initialization*
- SE-0371 *Isolated synchronous deinit*
- WWDC21, *Protect mutable state with Swift actors*
