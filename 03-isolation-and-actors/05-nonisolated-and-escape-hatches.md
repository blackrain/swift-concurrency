# 3.5 `nonisolated`, `nonisolated(unsafe)`, `assumeIsolated`, `@preconcurrency`: the escape hatches

## Why it matters
Static checking can't see everything. Delegate callbacks from Objective-C frameworks, C callbacks, legacy modules and hand-rolled synchronization all happen outside the compiler's view. Swift gives you a set of **escape hatches**. Each one moves a guarantee from compile time to runtime, or to you. An expert knows exactly what each hatch costs, and reaches for them rarely.

## Mental model

| Tool | Who guarantees safety | What happens if the guarantee is wrong |
|---|---|---|
| `nonisolated` | the compiler (the code can't touch isolated state) | doesn't compile |
| `MainActor.assumeIsolated { }` / `actor.assumeIsolated` | **a runtime check** | **traps** |
| `preconditionIsolated()` / `assertIsolated()` | a runtime check | traps (`assert…` only in debug builds) |
| `@preconcurrency` conformance | **a runtime check** inserted in each witness | **traps** |
| `@preconcurrency import` | nobody (diagnostics downgraded to warnings) | silent data race |
| `nonisolated(unsafe)` | **you** | silent data race |
| `@unchecked Sendable` | **you** | silent data race |

Prefer the hatches near the top of the table. A trap is far better than silent corruption.

## Core content

### `nonisolated`: safe opt-out
On a member of an isolated type, `nonisolated` means "this doesn't need the actor". The compiler then forbids it from touching isolated state ([3.1](01-actors.md)). On a type in a MainActor-default module, `nonisolated` makes the whole type nonisolated ([3.4](04-approachable-concurrency.md)). Since Swift 6.1 (SE-0449), you can also put `nonisolated` on types and extensions to block global-actor inference.

<!-- check: lib -->
```swift
@MainActor
final class Settings {
    var theme = "light"
    nonisolated let appVersion = "1.0"                   // immutable + Sendable: safe from anywhere
    nonisolated func cacheKey(for id: Int) -> String {   // uses no isolated state
        "settings.\(id)"
    }
}

nonisolated extension Settings {
    static func defaultsKey() -> String { "settings" }   // the whole extension is nonisolated (SE-0449)
}
```

### `assumeIsolated`: "the compiler can't see it, but I know I'm on this actor"
Typical case: a framework calls your delegate on the main thread, but the protocol isn't annotated.

<!-- check: lib -->
```swift
import Foundation

@MainActor final class Player {
    var position = 0.0
    func update(_ p: Double) { position = p }
}

protocol LegacyObserver: AnyObject { func progressChanged(_ value: Double) }  // nonisolated, synchronous

@MainActor final class PlayerObserver: LegacyObserver {
    let player = Player()
    nonisolated func progressChanged(_ value: Double) {
        // The framework's documentation promises: always called on the main thread.
        MainActor.assumeIsolated {
            player.update(value)                         // synchronous access, no Task, no hop
        }
    }
}
```

Facts, verified with Swift 6.4:
- `assumeIsolated` only exists for **synchronous** code. Calling it from an async function fails with `static method 'assumeIsolated' is unavailable from asynchronous contexts; await the call to the @MainActor closure directly`. In async code, just `await` the isolated function.
- **If the assumption is wrong, the process traps** (`SIGTRAP`, exit code 133). In the crash log, the stack shows `MainActor.assumeIsolated` → `swift_task_isCurrentExecutorWithFlagsImpl` → `_swift_task_checkIsolatedSwift` → `dispatch_assert_queue`. For the main actor, the runtime asks libdispatch whether the current thread is running on the main queue. The Swift-level message, defined in `stdlib/public/Concurrency/MainActor.swift`, is `Incorrect actor executor assumption; Expected same executor as MainActor.` In my runs, the failure was reported through libdispatch's assertion instead (visible in the crash report, not on stderr).
- `actor.assumeIsolated { isolatedSelf in … }` works the same way for actor instances.

**Compare this with `Task { @MainActor in … }`:** a task is asynchronous (it runs later), and it doesn't check anything. `assumeIsolated` runs now, synchronously, and verifies its assumption.

### `preconditionIsolated` / `assertIsolated`
<!-- check: lib -->
```swift
@MainActor final class Cache { var entries: [String: Int] = [:] }

func legacyEntryPoint(_ cache: Cache) {
    MainActor.preconditionIsolated("legacyEntryPoint must be called on the main actor")
    // still no *static* access here: preconditionIsolated only checks
}
```

Use them to document and enforce threading contracts at the boundary with legacy code. Per the stdlib docs, `assertIsolated` stops execution in `-Onone` builds and playgrounds, and "in `-O` builds … the isolation check is not performed". `preconditionIsolated` is also checked in `-O` builds.

### `@preconcurrency` conformances: runtime-checked bridging
<!-- check: lib -->
```swift
protocol Delegate { func didUpdate() }                   // nonisolated requirement

@MainActor final class ViewController {}
extension ViewController: @preconcurrency Delegate {
    func didUpdate() { print("updated") }                // main-actor witness
}
```

The compiler accepts the conformance, and **inserts a dynamic isolation check** into the witness. I verified this: calling `didUpdate()` through `any Delegate` from a `@concurrent` function trapped (exit code 133), and the crash stack showed `protocol witness for Delegate.didUpdate() in conformance ViewController` → `_checkExpectedExecutor` → `dispatch_assert_queue`. That's the bridge for "my protocol isn't annotated yet, but in practice it's only called on main". When you can, prefer an isolated conformance (`extension ViewController: @MainActor Delegate`, [3.4](04-approachable-concurrency.md)), which is checked at compile time.

Swift 6 also performs the same kind of runtime check at other boundaries with code that wasn't compiled under strict checking. SE-0423 adds dynamic checks when isolated synchronous functions are called through `@preconcurrency` APIs, or from modules in the Swift 5 language mode.

### `@preconcurrency import`
<!-- check: skip -->
```swift
@preconcurrency import SomeLegacySDK
```

This downgrades `Sendable`-related errors about types from that module to warnings (or hides them). The compiler even suggests it: `add '@preconcurrency' to treat 'Sendable'-related errors from module 'Dispatch' as warnings [#AddPreconcurrencyImport]` (seen in [2.3](../02-structured-concurrency/03-cancellation.md) research). It's a **migration tool**. Track each one, and remove it when the dependency gets annotated.

### `nonisolated(unsafe)`: you're on your own
<!-- check: lib -->
```swift
import Synchronization

// ⚠️ OK only because every access goes through `lock`.
nonisolated(unsafe) var legacyRegistry: [String: Int] = [:]
let lock = Mutex(())

func register(_ k: String, _ v: Int) {
    lock.withLock { _ in legacyRegistry[k] = v }
}
```

Apply `nonisolated(unsafe)` to global/static variables and to stored properties to disable isolation checking for that storage. You can also apply it to a **local** `let` to stop the region checker from complaining about a value you know is safe to send. In new code, `Mutex<[String: Int]>` (with the state *inside* the mutex) is strictly better: it's a compiler-checked `Sendable` value, and you can't forget the lock ([4.3](../04-sendable-and-safety/03-unchecked-mutex-atomics.md)).

## Pitfalls & compiler errors
- **`assumeIsolated` as a way to silence compile errors.** If you can't *prove* the code runs on that actor, you've turned a compile error into a crash. Look at the caller instead.
- **`Task { @MainActor in }` inside a delegate callback** where `assumeIsolated` would do. It adds a delay and breaks the synchronous ordering the framework expects. For example, `UITableViewDataSource` methods must return their values synchronously.
- **Leaving `@preconcurrency import`s in place forever.** They hide real bugs.
- `nonisolated(unsafe)` on a `let` of a `Sendable` type: it's unnecessary, and the compiler says so.

## Under the hood
- `assumeIsolated` asks the runtime whether the current executor is the expected one (`swift_task_isCurrentExecutor…`). If the current thread isn't running a Swift task on that executor, the runtime falls back to the executor's `checkIsolated()` (SE-0424). For the main actor, that's a libdispatch queue assertion. If the check fails, the process traps. That's how `assumeIsolated` works correctly even when it's called from a plain GCD callback on the main queue, where no Swift task is running.
- `@preconcurrency` conformance witnesses get a compiler-inserted `_checkExpectedExecutor` call at entry (visible in the crash stack above).
- `SerialExecutor.isIsolatingCurrentContext() -> Bool?` (SE-0471, Swift 6.2) lets a custom executor *answer* "am I the current context?" instead of crashing. The runtime calls it *before* `checkIsolated()`, and the default implementation returns `nil` (meaning "unknown"). See [7.2](../07-internals/02-executors.md).

## Exercises
1. A C library calls `void (*callback)(int)` on its own private thread. Write the Swift bridge that forwards the value to a `@MainActor` model safely. (Hint: assumeIsolated is *wrong* here. Why?)
2. Convert a `@preconcurrency` conformance to an isolated conformance. When would generic callers stop compiling?
3. Replace a `nonisolated(unsafe) var` global plus a lock with a `Mutex`.

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
import Synchronization

@MainActor final class Model { var value = 0 }

// 1. The callback runs on a private thread → hop asynchronously. Never assumeIsolated here.
func makeCallback(model: Model) -> @Sendable (Int32) -> Void {
    { value in
        Task { @MainActor in model.value = Int(value) }   // `Model` is @MainActor, so it's Sendable
    }
}

// 3.
let registry = Mutex<[String: Int]>([:])
func register(_ k: String, _ v: Int) { registry.withLock { $0[k] = v } }
```
1. `assumeIsolated` would trap, because the callback isn't on the main thread.
2. Isolated conformances can't be used from generic code running off the main actor. Callers that use the conformance in nonisolated or `@concurrent` generic contexts get `[#IsolatedConformances]` errors, where before they compiled and were checked at runtime.
</details>

## Check yourself
1. What happens at runtime if `MainActor.assumeIsolated` is called on a background thread?
2. Which is safer: `@preconcurrency import` or a `@preconcurrency` conformance? Why?
3. Can you call `assumeIsolated` from an `async` function?

<details><summary>Answers</summary>

1. The process traps.
2. A `@preconcurrency` conformance, because it inserts runtime checks. `@preconcurrency import` just silences diagnostics.
3. No. It's unavailable from asynchronous contexts. `await` the isolated call instead.
</details>

## Further reading
- SE-0337 *Incremental migration to concurrency checking* (`@preconcurrency`)
- SE-0392 *Custom Actor Executors* (`assumeIsolated`)
- SE-0423 *Dynamic actor isolation enforcement from non-strict-concurrency contexts*
- SE-0424 *Custom isolation checking for SerialExecutor*
- SE-0449 *Allow `nonisolated` to prevent global actor inference*
- SE-0471 *Improved Custom SerialExecutor isolation checking*
