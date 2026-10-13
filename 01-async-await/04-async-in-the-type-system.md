# 1.4 `async` in the type system, and a first look at `async let`

## Why it matters
`async` is an **effect**, like `throws`. It's part of a function's type, and it changes how protocol witnesses, overloads and closure types work. Knowing these rules lets you design APIs that are pleasant to call from both sync and async code. This chapter also introduces `async let`, which is where async code starts to run concurrently.

## Mental model

```
  () -> T   is a subtype of   () async -> T      (a sync function can be used where async is expected)
  () async -> T  is NOT a subtype of  () -> T     (the reverse would let a sync caller suspend)
```

Same shape as `throws`: non-throwing is a subtype of throwing.

## Core content

### Subtyping, witnesses and overloads (all verified with Swift 6.4)

<!-- check: lib -->
<!-- check: output "async ctx picks: async" -->
<!-- check: output "sync ctx picks: sync" -->
```swift
protocol Store {
    func load() async throws -> Int
}

struct Memory: Store {
    func load() -> Int { 1 }              // ✅ a sync, non-throwing method satisfies an async throws requirement
}

func syncF() -> Int { 1 }

func value() -> String { "sync" }         // overloading on `async` is allowed
func value() async -> String { "async" }

func syncCaller() { print("sync ctx picks:", value()) }

@concurrent func demo() async {
    let asyncF: () async -> Int = syncF   // ✅ sync → async conversion
    print("async ctx picks:", await value())
    syncCaller()
    let store: any Store = Memory()
    print(try! await store.load(), await asyncF())
}

@main struct Main { static func main() async { await demo() } }
```

The rules:
1. **A sync function converts to an async function type**, but not the other way around.
2. **A sync method can satisfy an `async` requirement**, but an `async` method can't satisfy a sync one. The compiler says `type 'S' does not conform to protocol 'P'`. When you design protocols, mark requirements `async` if *any* conformer might need to suspend. Sync conformers still work.
3. **Overloads that differ only in `async`** are allowed. In an async context the async overload wins, and in a sync context the sync one is the only candidate. Apple uses this for APIs that have both forms.

> Calling through a protocol: even though `Memory.load()` is sync, calling it through `any Store` needs `try await`, because the *requirement* is `async throws`. Calling it on the concrete `Memory` type needs neither, and the compiler warns `no 'async' operations occur within 'await' expression` if you write `await`.

### Async closures and autoclosures

<!-- check: lib -->
```swift
func measure<T>(_ body: () async throws -> T) async rethrows -> T {
    let start = ContinuousClock.now
    defer { print("took", ContinuousClock.now - start) }
    return try await body()
}

func orDefault(_ value: @autoclosure () async -> Int?, default d: Int) async -> Int {
    await value() ?? d
}
```

A closure is inferred to be `async` if its body contains an `await`. Async autoclosures let you write APIs that evaluate an async expression lazily.

### A first look at `async let`
`await` on its own is sequential. `async let` starts a **child task** that runs *concurrently* with the rest of the function:

<!-- check: output "both done concurrently" -->
```swift
func slow(_ name: String, ms: Int) async -> String {
    try? await Task.sleep(for: .milliseconds(ms))
    return name
}

let start = ContinuousClock.now
async let a = slow("a", ms: 200)       // starts now
async let b = slow("b", ms: 200)       // starts now, runs concurrently with `a`
let (x, y) = await (a, b)              // wait for both
let elapsed = ContinuousClock.now - start
print(x, y, elapsed < .milliseconds(350) ? "both done concurrently" : "sequential?!", "both done")
```

In this program, both sleeps overlap and the total time is about 200 ms rather than 400 ms. (I verified this. The check uses a 350 ms bound to leave room for scheduling noise.) Part 2 covers `async let` in depth: scoping, cancellation and how it compares to task groups.

## Pitfalls & compiler errors
- `type '…' does not conform to protocol '…'`, with a note about `async` → you wrote an async witness for a sync requirement. Make the requirement `async`, or make the witness sync.
- **Adding `async` to a public protocol requirement is source-breaking** for callers, who now need `await`. Removing it is source-breaking for conformers whose witnesses are `async`. Decide early.
- `rethrows` works with async closures, as `measure` above shows. Typed throws (`throws(E)` generic over `E`) is the more general tool.

## Under the hood
- The `() -> T` to `() async -> T` conversion creates a small **thunk**: an async function that calls the sync one and returns.
- The overload rule is from SE-0296 (*Overloading and overload resolution*). In a synchronous context, resolution prefers the non-`async` function, because a sync context can't call an async one. In an asynchronous context, it prefers the `async` function, because such contexts "should avoid stepping out of the asynchronous model into blocking APIs".

## Exercises
1. Design a `protocol ImageLoader` that both a sync in-memory cache and an async network loader can conform to. Implement both.
2. Write `func timed<T>(_ op: () async throws -> T) async rethrows -> (T, Duration)`.
3. Using `async let`, fetch three values concurrently and return their sum.

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
import Foundation

protocol ImageLoader { func image(named: String) async throws -> Data }

struct CacheLoader: ImageLoader {
    let cache: [String: Data]
    func image(named: String) -> Data { cache[named] ?? Data() }
}

struct NetworkLoader: ImageLoader {
    func image(named: String) async throws -> Data {
        try await Task.sleep(for: .milliseconds(10))
        return Data()
    }
}

func timed<T>(_ op: () async throws -> T) async rethrows -> (T, Duration) {
    let clock = ContinuousClock()
    var result: T?
    let d = try await clock.measure { result = try await op() }
    return (result!, d)
}

func number(_ n: Int) async -> Int { n }

func sum3() async -> Int {
    async let a = number(1)
    async let b = number(2)
    async let c = number(3)
    return await a + b + c
}
```
</details>

## Check yourself
1. Can a protocol with an `async` requirement be satisfied by a sync method?
2. Why isn't `() async -> T` a subtype of `() -> T`?
3. What's the difference between `let x = await f()` and `async let x = f()`?

<details><summary>Answers</summary>

1. Yes.
2. A sync caller can't suspend, so it has no way to wait for an async function.
3. The first waits for `f()` right there. The second starts `f()` as a concurrent child task, and you wait for it later with `await x`.
</details>

## Further reading
- SE-0296 *Async/await*, especially "Overloading and overload resolution"
- SE-0317 *`async let` bindings*
