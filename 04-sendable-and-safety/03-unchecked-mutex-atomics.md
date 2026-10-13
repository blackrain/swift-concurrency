# 4.3 `Mutex`, `Atomic`, locks, and `@unchecked Sendable`

## Why it matters
Actors aren't the only tool, and they're often the wrong one for tiny, synchronous, hot-path state. The `Synchronization` module (Swift 6.0) provides `Mutex` and `Atomic`, which are compiler-checked and `Sendable`. With them, you rarely need `@unchecked Sendable` again.

## Mental model

```
Need to protect state?
├─ the operations are async, or long, or need fairness/backpressure ─▶ actor
├─ tiny synchronous critical sections, sync callers ────────────────▶ Mutex<State>
├─ a single integer/bool/pointer, lock-free ────────────────────────▶ Atomic<Value>
└─ interop with an existing lock or queue you can't change ─────────▶ @unchecked Sendable + a documented invariant
```

## Core content

### `Mutex<Value>` (Synchronization, macOS 15 / iOS 18+)

<!-- check: lib -->
```swift
import Synchronization

final class Stats: Sendable {                         // ✅ no @unchecked needed
    private let counts = Mutex<[String: Int]>([:])

    func hit(_ key: String) {
        counts.withLock { $0[key, default: 0] += 1 }
    }
    func snapshot() -> [String: Int] {
        counts.withLock { $0 }
    }
}
```

The key property is that **the state lives inside the mutex**. You can only reach it through `withLock`, so forgetting to lock is impossible. Facts from the 6.4 SDK (`Synchronization.swiftinterface`) and the compiler:
- `struct Mutex<Value: ~Copyable>: ~Copyable`, with `@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)`.
- `extension Mutex: @unchecked Sendable where Value: ~Copyable`. A `Mutex` is `Sendable` **whatever `Value` is**, because values only enter and leave through `sending` boundaries:
  `borrowing func withLock<Result, E>(_ body: (inout sending Value) throws(E) -> sending Result) throws(E) -> sending Result`.
- `withLockIfAvailable` returns `nil` instead of blocking. SE-0512 documents that it **cannot fail spuriously**.
- **The closure must be synchronous** (verified): `cannot pass function of type '(inout sending Int) async -> sending ()' to parameter expecting synchronous function type`. That makes "holding a lock across an `await`" a compile error.
- `Mutex` is noncopyable. Store it in a `let` property of a class, or as a global, and pass it as `borrowing`. A plain parameter fails with `parameter of noncopyable type 'Mutex<Int>' must specify ownership`.

### `Atomic<Value>`
<!-- check: lib -->
```swift
import Synchronization

final class RequestIDs: Sendable {
    private let next = Atomic<Int>(0)
    func make() -> Int {
        next.wrappingAdd(1, ordering: .relaxed).oldValue
    }
}
```

- An `Atomic` **must be declared with `let`**: `variable of type 'Atomic<Int>' must be declared with a 'let'` (verified). It's `@_staticExclusiveOnly`, so its memory location is stable.
- `Atomic` is `Sendable` only when `Value: Sendable`.
- Every operation takes an explicit memory ordering, and the ordering must be a compile-time constant (`@_semantics("atomics.requires_constant_orderings")`). Start with `.sequentiallyConsistent`, and relax it only if you can prove that's correct. `.relaxed` is fine for standalone counters that don't publish other data.
- Operations: `load`, `store`, `exchange`, `compareExchange(expected:desired:ordering:)`, and for integers `add`/`subtract`/`wrappingAdd`/`wrappingSubtract`, `bitwiseAnd`/`Or`/`Xor`, `min`/`max`. The arithmetic ones return `(oldValue:newValue:)`.

### Rough costs (measured, not a benchmark suite)
One million uncontended increments on an Apple-silicon Mac, `-O`, Swift 6.4, two runs:

| Mechanism | Total |
|---|---|
| `Atomic.add(1, ordering: .relaxed)` | ~2 ms |
| `Mutex.withLock { $0 += 1 }` | 42–64 ms |
| `await actor.inc()` from main-actor top-level code | ~2.7 s |

The actor number is a worst case: every call hops main actor → actor → main actor. Calls from a nonisolated context are cheaper. The lesson isn't "actors are slow". It's that **a cross-actor call is a scheduling operation, not a memory operation**. Design actor APIs to be coarse-grained, and use `Mutex` or `Atomic` for fine-grained hot state.

### `@unchecked Sendable`: when, and how to do it responsibly
Legitimate uses:
- a type whose synchronization the compiler can't see (an existing `DispatchQueue`, an `NSLock`, `os_unfair_lock`);
- C/Objective-C wrappers whose thread-safety is documented;
- deployment targets older than iOS 18 / macOS 15, where `Mutex` isn't available. (`OSAllocatedUnfairLock` from the `os` module is an option on iOS 16+ / macOS 13+.)

Rules:
1. Make every stored `var` `private`.
2. Write the synchronization invariant as a comment on the type.
3. Never hand out references to the protected state.
4. Run the tests under Thread Sanitizer.

<!-- check: lib -->
```swift
import Foundation

/// Invariant: `storage` is only accessed while holding `lock`.
final class LegacyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func value(for key: String) -> Data? { lock.withLock { storage[key] } }
    func set(_ data: Data, for key: String) { lock.withLock { storage[key] = data } }
}
```

## Pitfalls & compiler errors
- **`@unchecked Sendable` on a type with mutable state and no lock.** That's a data race you've hidden from the compiler.
- **Using an `Atomic` for multi-field invariants.** Two atomics aren't one transaction. Use a `Mutex` around a struct.
- **Long or blocking work inside `withLock`.** Every other thread that needs the lock is blocked while it runs, and in async code that includes cooperative-pool threads.
- **Keeping both a `Mutex` and a separate `var` "protected by" it.** Put the state *in* the mutex.

## Under the hood
- On Darwin, `Mutex` is backed by `os_unfair_lock`. On Linux it's a futex-based lock. (The `_MutexHandle` type is platform-specific.)
- `Atomic` uses `@_rawLayout(like: Value.AtomicRepresentation)` and compiles directly to hardware atomic instructions. That's why it must have a stable address (`let`, noncopyable).
- Because `withLock` uses `inout sending Value`, the region checker makes sure that no non-`Sendable` reference to the protected state escapes the lock ([4.2](02-region-isolation.md)).

## Exercises
1. Convert a `class Registry { private let queue = DispatchQueue(label: "r"); private var items: [String] = [] }` with `queue.sync` accessors into a `Mutex`-based `Sendable` class.
2. Implement a thread-safe "once" flag with `Atomic<Bool>` and `compareExchange`.
3. When would you still pick an actor over `Mutex` for a cache?

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
import Synchronization

final class Registry: Sendable {
    private let items = Mutex<[String]>([])
    func add(_ s: String) { items.withLock { $0.append(s) } }
    var all: [String] { items.withLock { $0 } }
}

final class Once: Sendable {
    private let done = Atomic<Bool>(false)
    /// Returns true exactly once, for the first caller.
    func claim() -> Bool {
        done.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
    }
}
```
3. When filling the cache requires async work (network or disk) and you want concurrent requests to be *coalesced* (the in-flight `Task` pattern from [3.1](../03-isolation-and-actors/01-actors.md)). A `Mutex` can't be held across that `await`.
</details>

## Check yourself
1. Why is `Mutex<NonSendableClass>` itself `Sendable`?
2. Can you `await` inside `withLock`?
3. Why must an `Atomic` be a `let`?

<details><summary>Answers</summary>

1. The value can only be accessed under the lock, and it enters and leaves through `sending` parameters, so no unsynchronized alias can exist.
2. No. The closure parameter is synchronous (it's a compile error).
3. Atomic operations need a single, stable memory location. A `var` could be copied or moved.
</details>

## Further reading
- SE-0410 *Low-Level Atomic Operations*
- SE-0433 *Synchronous Mutual Exclusion Lock*
- SE-0512 *Document that `Mutex.withLockIfAvailable(_:)` cannot spuriously fail*
