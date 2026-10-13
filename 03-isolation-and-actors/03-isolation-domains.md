# 3.3 Isolation domains, `isolated` parameters, `#isolation`, `@isolated(any)`

## Why it matters
Every line of Swift 6 code runs in exactly one **isolation domain**. Data-race safety comes down to one rule: *non-`Sendable` state must never be reachable from two domains at once.* An expert reads code by asking, for each function, "which domain does this run in, and what crosses a boundary here?" This chapter gives you the tools to answer that question, and to write functions that adapt to their caller's domain.

## Mental model

```
Isolation domains:
  • nonisolated          — no actor; synchronous code runs wherever its caller is
  • actor instance `a`   — the state of one actor object
  • global actor @G      — everything annotated @G (e.g. @MainActor)

Boundary crossing = a call that changes domain → needs `await`, and
                    everything passed across must be Sendable or `sending`.
```

Isolation is a **static** property of declarations. The compiler knows it for every function and closure, and it inserts hops only where domains change.

## Core content

### Where does a function run?
| Declaration | Runs on |
|---|---|
| method of `actor A` | `A`'s executor |
| `@MainActor func` / member of a `@MainActor` type | the main actor |
| **synchronous** nonisolated function | **whatever the caller is on** (it can't hop) |
| **async** nonisolated function, default Swift 6 | **the global concurrent executor** (it hops off the caller's actor) |
| async nonisolated function with `NonisolatedNonsendingByDefault`, or marked `nonisolated(nonsending)` | **the caller's actor** |
| `@concurrent` async function | the global concurrent executor, always |
| a function with an `isolated` parameter | the actor passed in that parameter |

The two rows about *async nonisolated functions* are the most consequential behavior change in recent Swift. They're the subject of [3.4](04-approachable-concurrency.md). I measured them in [Part 1](../01-async-await/01-async-functions.md): in default Swift 6 mode, a nonisolated async function called from the main actor ran on a **background thread**. With the upcoming feature enabled, it ran on the **main thread**.

### The problem that isolation-polymorphic functions solve
Take a plain async helper that works on a non-`Sendable` object owned by the main actor:

<!-- check: lib -->
<!-- check: error "sending 'self.log' risks causing data races" -->
```swift
final class Log { var lines: [String] = [] }       // not Sendable

func appendAsync(_ log: Log) async { log.lines.append("x") }

@MainActor final class Screen {
    let log = Log()
    func run() async {
        await appendAsync(log)    // ❌ default Swift 6: the call leaves the main actor
    }
}
```

The 6.4 diagnostic says it all: `sending 'self.log' risks causing data races`, with the note *"sending main actor-isolated 'self.log' to @concurrent global function 'appendAsync' risks causing data races between @concurrent and main actor-isolated uses"*. In default Swift 6 mode, a nonisolated async function *is* effectively `@concurrent`.

There are three fixes. Each one makes `appendAsync` run in the **caller's** domain:

**Fix 1: an `isolated` parameter defaulting to `#isolation` (works since Swift 6.0):**

<!-- check: output "added on Optional(Swift.MainActor)" -->
```swift
final class Log { var lines: [String] = [] }

func appendAsync(_ log: Log, isolation: isolated (any Actor)? = #isolation) async {
    try? await Task.sleep(for: .milliseconds(1))
    log.lines.append("added on \(String(describing: isolation))")
}

@MainActor final class Screen {
    let log = Log()
    func run() async {
        await appendAsync(log)                  // #isolation expands to MainActor.shared here
        print(log.lines)
    }
}

await Screen().run()
```

Verified output: `["added on Optional(Swift.MainActor)"]`.

**Fix 2: `nonisolated(nonsending)` (Swift 6.2, SE-0461)**, which says the same thing more concisely:

<!-- check: lib -->
```swift
final class Log { var lines: [String] = [] }

nonisolated(nonsending) func appendAsync(_ log: Log) async { log.lines.append("x") }

@MainActor final class Screen {
    let log = Log()
    func run() async { await appendAsync(log) }    // ✅ runs on the main actor
}
```

**Fix 3: enable `NonisolatedNonsendingByDefault`.** With the upcoming feature on, the *original* unannotated code compiles cleanly (verified). That's what Xcode's "Approachable Concurrency" setting does ([3.4](04-approachable-concurrency.md)).

### `isolated` parameters
A parameter marked `isolated` makes the function run on that actor, with synchronous access to its state:

<!-- check: output "2" -->
```swift
actor Counter { var value = 0 }

func incrementTwice(_ c: isolated Counter) {   // runs ON `c`
    c.value += 1                               // synchronous access, no await
    c.value += 1
}

let counter = Counter()
await incrementTwice(counter)                  // callers must hop to `counter`
print(await counter.value)
```

This is how you write "extension-like" functions that operate on an actor from outside its declaration. Actor methods themselves are just functions with an implicit `isolated self`.

- `isolated (any Actor)?` accepts any actor, or `nil` (nonisolated). That's the polymorphic form.
- `#isolation` is a macro that expands to the caller's current isolation, typed as `(any Actor)?`. It evaluates to `MainActor.shared` in `@MainActor` code, to `self` inside an actor method, and to `nil` in nonisolated code.
- Many stdlib APIs use this pattern: `withTaskGroup(…, isolation: isolated (any Actor)? = #isolation, …)`, and so did the continuation APIs before 6.4 adopted `nonisolated(nonsending)`.

### `@isolated(any)` function types (SE-0431)
A function value can carry its isolation **dynamically**:

<!-- check: output "closure isolation: Optional(Swift.MainActor)" -->
```swift
func describe(_ f: @isolated(any) () async -> Void) {
    print("closure isolation:", String(describing: f.isolation))
}

@MainActor func makeClosures() {
    describe { @MainActor in }       // explicitly MainActor
    describe { }                     // formed in @MainActor code → also MainActor (verified)
}

makeClosures()
```

- `f.isolation` returns `(any Actor)?`.
- Calling an `@isolated(any)` function requires `await`, because it might need to hop.
- The `Task` initializers take `@isolated(any)` operations. That's how the runtime can **start a new task directly on the right executor** instead of starting it on the global pool and hopping. A closure written in `@MainActor` code is enqueued straight onto the main actor.

### Closure isolation inference
- A closure formed **inside an isolated context** that isn't `@Sendable` or `sending` inherits that isolation. (Verified: `describe { }` inside `@MainActor` code reported `MainActor`.)
- `@Sendable` and `sending` closures passed to concurrent APIs don't inherit isolation by default. Only parameters marked `@_inheritActorContext`, as on `Task.init`, do, and for an actor *instance* only if the closure captures the isolated parameter ([2.1](../02-structured-concurrency/01-tasks.md)).
- You can always write isolation explicitly: `{ @MainActor in … }`.

## Pitfalls & compiler errors
- `sending '…' risks causing data races [#RegionIsolation::SendingRisksDataRace]` with "to @concurrent global function": a non-`Sendable` value is leaving your actor because the callee runs on the global executor. Use one of the three fixes above.
- **Confusing "nonisolated" with "runs in the background".** A *synchronous* nonisolated function runs on its caller's thread, which might be the main thread.
- **`#isolation` in a default argument is evaluated at the call site.** That's the point: it expands to the caller's isolation, not the callee's.

## Under the hood
- An `isolated` parameter tells the compiler to emit a **hop to that actor's executor** at the function's entry (if needed), and to treat the parameter as the current isolation.
- `nonisolated(nonsending)` functions receive the caller's isolation as an **implicit parameter** in their calling convention. That's how they can stay on the caller's actor without a visible `isolated` parameter. Because this changes the ABI, the 6.4 SDK uses `@abi(… withCheckedContinuationNonisolatedNonsending …)` declarations, so that the new `nonisolated(nonsending)` APIs can coexist with the old symbols.
- An `@isolated(any)` function value carries its isolation with it, so `.isolation` is read from the value itself. SE-0431 notes a back-deployment limitation: using such a type as a **generic argument** (for example `[@isolated(any) () -> ()]`) needs new runtime metadata support. On older OSes, wrap the function in a single-field `struct` instead.
- From SE-0461: `nonisolated(nonsending)` "is accomplished by implicitly passing an optional actor parameter to the async function".

## Exercises
1. Write a generic `func withRetry<T>(times: Int, isolation: isolated (any Actor)? = #isolation, _ op: () async throws -> T) async throws -> T` that can be called from an actor and mutate that actor's state inside `op` without `await`.
2. Rewrite exercise 1 using `nonisolated(nonsending)`.
3. Explain why a synchronous nonisolated function never needs `isolated` or `nonsending` annotations.

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
func withRetry<T>(times: Int, isolation: isolated (any Actor)? = #isolation,
                  _ op: () async throws -> T) async throws -> T {
    var last: (any Error)?
    for _ in 0..<times {
        do { return try await op() } catch { last = error }
    }
    throw last!
}

nonisolated(nonsending) func withRetry2<T>(times: Int, _ op: nonisolated(nonsending) () async throws -> T) async throws -> T {
    var last: (any Error)?
    for _ in 0..<times {
        do { return try await op() } catch { last = error }
    }
    throw last!
}

actor Downloader {
    var attempts = 0
    func fetch() async throws -> Int {
        try await withRetry(times: 3) {
            attempts += 1               // synchronous access: the closure runs on the actor
            return attempts
        }
    }
}
```
3. A synchronous function can't suspend or hop, so it always runs on its caller's executor. It's already "polymorphic" in its isolation.
</details>

## Check yourself
1. In default Swift 6 mode (no upcoming features), where does `func f() async` run when it's called from `@MainActor` code?
2. What does `#isolation` evaluate to inside an actor method?
3. Why does calling an `@isolated(any)` function require `await`?

<details><summary>Answers</summary>

1. On the global concurrent executor. It hops off the main actor (verified in [1.1](../01-async-await/01-async-functions.md)).
2. `self`, the actor (as `(any Actor)?`).
3. The function may be isolated to an actor other than the caller's, so the call might have to hop.
</details>

## Further reading
- SE-0313 *Improved control over actor isolation* (`isolated` parameters)
- SE-0420 *Inheritance of actor isolation* (`#isolation`)
- SE-0431 *`@isolated(any)` Function Types*
- SE-0461 *Run nonisolated async functions on the caller's actor by default*
