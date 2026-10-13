# 4.4 The Swift 6 diagnostics catalogue

## Why it matters
You'll spend more time reading concurrency diagnostics than writing concurrency features. This chapter is a reference. Every entry is a **real diagnostic produced by Swift 6.4**: each "❌" block below is compiled by this guide's checker, which confirms that the quoted text appears. Each "✅" block is the fix, and it compiles cleanly.

## Mental model: how to read any concurrency diagnostic
Ask three questions:
1. **Which isolation domains are involved?** The message names them: "main actor-isolated", "actor-isolated", "nonisolated", "@concurrent", "local", "task-isolated".
2. **What's crossing the boundary?** A call, a value, a closure, a conformance?
3. **Which fix keeps the *design* intact?** Change the isolation (where the code runs), change the type (make it `Sendable`), or change ownership (`sending`, copy the value, stop sharing it).

Two practical tips:
- The `[#GroupName]` suffix names a diagnostic group. The compiler prints a documentation link for each group, for example `<https://docs.swift.org/compiler/documentation/diagnostics/isolated-conformances>`.
- Region-based errors (`[#RegionIsolation…]`) appear only after all type errors are fixed ([4.1](01-sendable-and-sending.md)).

## Core content: the catalogue

### 1. Global mutable state — `[#MutableGlobalVariable]`
<!-- check: lib -->
<!-- check: error "is not concurrency-safe because it is nonisolated global shared mutable state" -->
```swift
var requestCount = 0                                     // ❌
```
<!-- check: lib -->
```swift
import Synchronization
@MainActor var requestCount = 0                          // ✅ isolate it…
let requestCounter = Atomic<Int>(0)                      // ✅ …or make it a Sendable `let`
```

### 2. Mutating a captured `var` in a `@Sendable` closure — `[#SendableClosureCaptures]`
<!-- check: lib -->
<!-- check: error "mutation of captured var 'count' in concurrently-executing code" -->
```swift
func run(_ f: @escaping @Sendable () -> Void) {}
func g() {
    var count = 0
    run { count += 1 }                                   // ❌
}
```
<!-- check: lib -->
```swift
import Synchronization
func run(_ f: @escaping @Sendable () -> Void) {}
func g() {
    let count = Atomic<Int>(0)                           // ✅ synchronized shared state
    run { count.add(1, ordering: .relaxed) }
}
```

### 3. Using a value after sending it — `[#RegionIsolation::SendingRisksDataRace]`
<!-- check: lib -->
<!-- check: error "sending 'b' risks causing data races" -->
```swift
final class Buffer { var bytes: [UInt8] = [] }
actor Sink { func consume(_ b: Buffer) {} }
@MainActor func f(_ s: Sink) async {
    let b = Buffer()
    await s.consume(b)
    b.bytes.append(1)                                    // ❌
}
```
<!-- check: lib -->
```swift
final class Buffer { var bytes: [UInt8] = [] }
actor Sink { func consume(_ b: Buffer) {} }
@MainActor func f(_ s: Sink) async {
    let b = Buffer()
    b.bytes.append(1)                                    // ✅ finish using it first…
    await s.consume(b)                                   // …then hand it off
}
```

### 4. A closure that captures mutable state passed to concurrent work — `[#RegionIsolation::SendingClosureRisksDataRace]`
<!-- check: lib -->
<!-- check: error "passing closure as a 'sending' parameter risks causing data races" -->
```swift
func total() async -> Int {
    var sum = 0
    await withTaskGroup { group in
        for i in 0..<10 { group.addTask { sum += i } }   // ❌
    }
    return sum
}
```
<!-- check: lib -->
```swift
func total() async -> Int {
    await withTaskGroup(of: Int.self) { group in
        for i in 0..<10 { group.addTask { i } }          // ✅ return values…
        return await group.reduce(0, +)                  // …and combine them in the parent
    }
}
```

### 5. A `Task` closure that captures a value which is used again — `[#RegionIsolation::SendingRisksDataRace]`
<!-- check: lib -->
<!-- check: error "sending value of non-Sendable type '() async -> ()' risks causing data races" -->
```swift
final class Counter { var n = 0 }
func f() async {
    let c = Counter()
    Task { c.n += 1 }                                    // ❌ c is captured…
    c.n += 1                                             // …and used concurrently here
}
```
<!-- check: lib -->
```swift
actor Counter { var n = 0; func bump() { n += 1 } }      // ✅ make the shared thing an actor
func f() async {
    let c = Counter()
    Task { await c.bump() }
    await c.bump()
}
```

### 6. A sync call into an actor from the wrong context — `[#ActorIsolatedCall]`
<!-- check: lib -->
<!-- check: error "call to main actor-isolated instance method 'stop()' in a synchronous nonisolated context" -->
```swift
@MainActor final class Player {
    func stop() {}
}
func shutdown(_ p: Player) {
    p.stop()                                             // ❌
}
```
<!-- check: lib -->
```swift
@MainActor final class Player { func stop() {} }
@MainActor func shutdown(_ p: Player) { p.stop() }       // ✅ isolate the caller…
func shutdownAsync(_ p: Player) async { await p.stop() } // ✅ …or hop
```

### 7. Mutating actor state from outside
<!-- check: lib -->
<!-- check: error "actor-isolated property 'items' can not be mutated from a nonisolated context" -->
```swift
actor Store { var items: [Int] = [] }
func add(_ s: Store) async { await s.items.append(1) }  // ❌
```
<!-- check: lib -->
```swift
actor Store { var items: [Int] = []; func add(_ i: Int) { items.append(i) } }
func add(_ s: Store) async { await s.add(1) }            // ✅ mutate through a method
```

### 8. A conformance that crosses into actor-isolated code — `[#ConformanceIsolation]`
<!-- check: lib -->
<!-- check: error "conformance of 'M' to protocol 'P' crosses into main actor-isolated code and can cause data races" -->
```swift
protocol P { func f() }
@MainActor final class M: P { func f() {} }              // ❌
```
The compiler suggests three fixes. Here they are in order of preference:
<!-- check: lib -->
```swift
protocol P { func f() }
@MainActor final class M1 {}
extension M1: @MainActor P { func f() {} }               // ✅ isolated conformance (SE-0470)

@MainActor final class M2: P { nonisolated func f() {} } // ✅ the witness doesn't need the actor

@MainActor final class M3 {}
extension M3: @preconcurrency P { func f() {} }          // ⚠️ runtime-checked (traps if misused)
```

### 9. Using an isolated conformance from the wrong context — `[#IsolatedConformances]`
<!-- check: lib -->
<!-- check: flags -default-isolation MainActor -->
<!-- check: error "main actor-isolated conformance of 'Item' to 'Decodable' cannot be used in @concurrent context" -->
```swift
import Foundation
struct Item: Codable { var name: String }                // MainActor-default module
@concurrent func load(_ d: Data) async throws -> Item {
    try JSONDecoder().decode(Item.self, from: d)         // ❌
}
```
<!-- check: lib -->
<!-- check: flags -default-isolation MainActor -->
```swift
import Foundation
nonisolated struct Item: Codable { var name: String }    // ✅
@concurrent func load(_ d: Data) async throws -> Item {
    try JSONDecoder().decode(Item.self, from: d)
}
```

### 10. Returning a non-`Sendable` value out of an actor — `[#RegionIsolation]`
<!-- check: lib -->
<!-- check: error "non-Sendable 'Doc'-typed result can not be returned from main actor-isolated instance method 'current()' to @concurrent context" -->
```swift
final class Doc { var text = "" }
@MainActor final class Editor {
    let doc = Doc()
    func current() -> Doc { doc }
}
@concurrent func export(_ e: Editor) async {
    let d = await e.current()                            // ❌
    print(d.text)
}
```
<!-- check: lib -->
```swift
final class Doc { var text = "" }
@MainActor final class Editor {
    let doc = Doc()
    func currentText() -> String { doc.text }            // ✅ return a Sendable snapshot
}
@concurrent func export(_ e: Editor) async {
    let text = await e.currentText()
    print(text)
}
```

### 11. Sending main-actor state to a nonisolated async function (default Swift 6 semantics)
<!-- check: lib -->
<!-- check: error "sending 'self.log' risks causing data races" -->
```swift
final class Log { var lines: [String] = [] }
func append(_ log: Log) async { log.lines.append("x") }
@MainActor final class Screen {
    let log = Log()
    func run() async { await append(log) }               // ❌ the callee runs on the global executor
}
```
<!-- check: lib -->
```swift
final class Log { var lines: [String] = [] }
nonisolated(nonsending) func append(_ log: Log) async { log.lines.append("x") }   // ✅ (or enable NonisolatedNonsendingByDefault)
@MainActor final class Screen {
    let log = Log()
    func run() async { await append(log) }
}
```

### 12. A mutable stored property in a `Sendable` class
<!-- check: lib -->
<!-- check: error "stored property 'count' of 'Sendable'-conforming class 'Stats' is mutable" -->
```swift
final class Stats: Sendable { var count = 0 }            // ❌
```
<!-- check: lib -->
```swift
import Synchronization
final class Stats: Sendable { let count = Mutex(0) }     // ✅
```

### 13. Calling async code from sync code
<!-- check: lib -->
<!-- check: error "'async' call in a function that does not support concurrency" -->
```swift
func load() async -> Int { 1 }
func button() { _ = load() }                             // ❌
```
<!-- check: lib -->
```swift
func load() async -> Int { 1 }
@MainActor func button() { Task { _ = await load() } }   // ✅ the entry point from sync UI code
```

### 14. Blocking APIs in async code
<!-- check: lib -->
<!-- check: error "is unavailable from asynchronous contexts" -->
```swift
import Dispatch
func waitForIt(_ s: DispatchSemaphore) async { s.wait() }   // ❌
```
Use an async equivalent: a continuation, an `AsyncStream`, or awaiting a task's value ([1.2](../01-async-await/02-bridging-continuations.md)).

### 15. Unused throwing task (warning, Swift 6.4) — `[#NoUseUnstructuredThrowingTask]`
<!-- check: lib -->
<!-- check: warning "is not used, which may accidentally ignore errors thrown inside the task" -->
```swift
func risky() throws {}
func start() { Task { try risky() } }                    // ⚠️
```
<!-- check: lib -->
```swift
func risky() throws {}
func start() { Task { do { try risky() } catch { print(error) } } }   // ✅
```

## Pitfalls
- **Fixing the symptom at the wrong layer.** Adding `@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency` makes the error disappear, and leaves the race in place.
- **Turning `@MainActor` into a reflex.** It fixes most app-level errors, but moving heavy work onto the main actor creates hitches. Make sure the work belongs there.
- **Ignoring the notes.** The second and third lines of a region diagnostic say *where* the value was sent and *where* it's used concurrently.

## Under the hood
Diagnostics come from two compiler stages:
- **Type checking** produces the isolation, `Sendable` and conformance errors (§1, 2, 6, 7, 8, 12, 13, 14).
- The **SIL `SendNonSendable` pass** produces the `[#RegionIsolation…]` errors (§3, 4, 5, 10, 11).

The second stage only runs once the first succeeds, so fixing one batch can reveal the next. And `swiftc -typecheck` never shows the SIL-stage errors at all ([0.2](../00-foundations/02-races-deadlocks-inversion.md), [4.2](02-region-isolation.md)).

## Exercises
For each snippet, name the domains, the thing crossing, and the best fix.
1. `@MainActor class VM { var items = [Item]() }` used from a `@concurrent` function that appends to `vm.items`.
2. A `Task.detached` that captures `self` in a `@MainActor` view model and calls `self.reload()`.
3. A nonisolated `func process(_ img: CGImage) async` called from the main actor with a `CGImage` property of a view model. (`CGImage` is a CF type.)

<details><summary>Solutions</summary>

1. Main actor ↔ `@concurrent`, a mutation of main-actor state. Fix: return the new items from the background function and append them on the main actor (`vm.items += await compute()`).
2. Detached (nonisolated) → main actor, a call to `reload()`. Fix: `await self.reload()` inside the detached task, or better, use `Task {}` (which inherits `@MainActor`), or a `@concurrent` helper.
3. Main actor → global executor (default semantics), passing a `CGImage`. In the macOS 27 SDK, `CGImage` **is** `Sendable` (verified: `needs<T: Sendable>(cgImage)` compiles), so this compiles, and nothing needs fixing. Ask the same question for any non-`Sendable` type: if the value is main-actor state, use `nonisolated(nonsending)`, or pass a `Sendable` snapshot.
</details>

## Check yourself
1. Which compiler stage reports `sending 'x' risks causing data races`?
2. What are the three kinds of fix to consider for any concurrency diagnostic?

<details><summary>Answers</summary>

1. The SIL region analysis (`SendNonSendable`), after type checking succeeds.
2. Change the isolation (where the code runs), change the type (`Sendable`), or change the ownership (`sending`, copies, not sharing).
</details>

## Further reading
- Swift compiler diagnostics documentation: https://docs.swift.org/compiler/documentation/diagnostics/
- *Migrating to Swift 6* guide: https://www.swift.org/migration/documentation/migrationguide/
