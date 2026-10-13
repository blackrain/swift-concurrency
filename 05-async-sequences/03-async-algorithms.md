# 5.3 swift-async-algorithms, and replacing Combine

## Why it matters
The standard library ships only the basic sequence operators. Real apps need time and combination: debounce a search field, merge several event sources, combine the latest values of two inputs, apply backpressure. Apple's open-source **swift-async-algorithms** package provides these. Together with `@Observable` ([5.4](04-observation.md)), it covers most of what apps used Combine for.

> **How the code in this chapter was verified:** this guide's checker compiles only standalone snippets, and this package is an external dependency. So the snippets here were compiled and run in a separate SwiftPM package against **swift-async-algorithms 1.1.7** (the latest tag, October 2026), with Swift 6.4. The outputs shown are from those runs.

## Mental model

```
Combine (push, subscription graph)     async-algorithms (pull, structured)
publisher.debounce(...).sink { }  ⇄   for await x in seq.debounce(...) { }  inside a Task / .task
AnyCancellable                    ⇄   the Task handle (or the view's lifetime with .task)
receive(on: DispatchQueue.main)   ⇄   consume in @MainActor code
```

## Core content

### Setup
<!-- check: skip -->
```swift
// Package.swift
.package(url: "https://github.com/apple/swift-async-algorithms", from: "1.1.7"),
// target dependency:
.product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
```

### Time-based: `debounce` (verified)
<!-- check: skip -->
```swift
import AsyncAlgorithms

let (queries, input) = AsyncStream.makeStream(of: String.self)
let task = Task {
    var out: [String] = []
    for await q in queries.debounce(for: .milliseconds(100)) { out.append(q) }
    return out
}
for q in ["s", "sw", "swi"] { input.yield(q); try await Task.sleep(for: .milliseconds(20)) }
try await Task.sleep(for: .milliseconds(200))
input.yield("swift")
try await Task.sleep(for: .milliseconds(200))
input.finish()
print(await task.value)          // ["swi", "swift"]
```

Throttling exists too, but in 1.1.7 it's spelled **`_throttle(for:clock:)`**. The leading underscore means the API isn't stable yet. With inputs every 25 ms and a 100 ms window, it delivered `[1, 5, 9, 10]`.

### Combining (verified outputs)
| Operator | Semantics | Example result |
|---|---|---|
| `merge(a, b)` | interleave the elements as they arrive | 5 elements from `[1,2,3]` and `[10,20]` |
| `zip(a, b)` | pairwise; ends when the shorter sequence ends | `["1a", "2b"]` |
| `combineLatest(a, b)` | emit the latest pair whenever either side emits (once both have emitted) | `["1a", "2a"]` |
| `chain(a, b)` | `a` then `b` | |
| `.removeDuplicates()` | drop *consecutive* duplicates | `[1,1,2,2,2,3,1]` → `[1, 2, 3, 1]` |
| `.chunks(ofCount: 3)` | batches | `[[1,2,3],[4,5,6],[7]]` |
| `.flatMapLatest { }` | map to an inner sequence, cancelling the previous one (Combine's `switchToLatest`) | |
| `.share()` | **multicast**: every iterator sees every element | A: `[1,2,3,4]`, B: `[1,2,3,4]` |

`share(bufferingPolicy:)` defaults to `.bounded(1)`, which **applies backpressure to the source**. That's the missing multicast piece from [5.2](02-asyncstream.md).

### `AsyncChannel`: backpressure (verified)
`AsyncChannel.send(_:)` is `async`. It **suspends until a consumer takes the element**. In my run, a `send` waited until the consumer started iterating 100 ms later.

<!-- check: skip -->
```swift
let channel = AsyncChannel<Int>()
Task {
    for i in 0..<100 { await channel.send(i) }   // the producer slows down to match the consumer
    channel.finish()
}
for await value in channel { /* slow processing */ _ = value }
```

There's also `AsyncThrowingChannel` (with `fail(_:)`), and `AsyncTimerSequence(interval:clock:)` for periodic ticks.

### A Combine migration table
| Combine | Swift concurrency |
|---|---|
| `PassthroughSubject` | `AsyncStream` + continuation (single consumer), or `AsyncChannel` (with backpressure) |
| `CurrentValueSubject` / `@Published` | an `@Observable` property, observed with `Observations` ([5.4](04-observation.md)) |
| `.sink { }` + `AnyCancellable` | `Task { for await … }` + `task.cancel()`, or SwiftUI `.task {}` |
| `.receive(on: DispatchQueue.main)` | consume in `@MainActor` code |
| `.debounce`, `.merge`, `.combineLatest`, `.zip`, `.removeDuplicates` | the same names in AsyncAlgorithms (throttle is `_throttle`) |
| `.switchToLatest()` | `.flatMapLatest { }` |
| `.share()` / `.multicast` | `.share()` |
| `Future` | an `async` function |
| `.retry(n)` | a `for` loop around `try await` ([0.3](../00-foundations/03-callbacks-and-gcd-problems.md)) |

You don't have to remove Combine. `publisher.values` (macOS 12 / iOS 15+) turns a Combine `Publisher` into an `AsyncSequence` (`AsyncPublisher` when `Failure == Never`, and a throwing variant otherwise), which lets you migrate incrementally.

## Pitfalls & compiler errors
- **Relying on the underscored `_throttle`.** It may change. Pin the package version.
- **Using `merge` and expecting ordering between sources.** Elements arrive in time order, and there's no other guarantee.
- **Forgetting that `for await` blocks the rest of the task.** Two independent streams need two child tasks (`async let` / a task group) or a `merge`.
- **Shared-sequence buffering:** with `.bounded(1)`, a slow subscriber slows down everyone.

## Under the hood
- Combining operators iterate their upstreams concurrently. In 1.1.7, `MergeStorage.startTask` creates an **unstructured `Task`** that runs a `withThrowingTaskGroup` with one child per upstream. The storage cancels that task when the downstream iterator terminates. That's why breaking out of a `for await` over `merge(...)` also stops the upstream iteration.
- `debounce` uses a `Clock`, and you can pass your own. That's how you test it deterministically ([7.5](../07-internals/05-clocks-and-time.md)).

## Exercises
1. Build a search pipeline: text input → `debounce(300 ms)` → `removeDuplicates()` → `flatMapLatest { query in results(for: query) }`.
2. Replace a Combine `@Published var isOnline` plus `.sink` with `@Observable` and `Observations`.
3. Why does `AsyncChannel` give you backpressure while `AsyncStream` doesn't?

<details><summary>Solutions</summary>

1. `for await results in input.debounce(for: .milliseconds(300)).removeDuplicates().flatMapLatest({ q in search(q) }) { render(results) }`, where `search` returns an `AsyncSequence` that the next query cancels.
2. See [5.4](04-observation.md).
3. `AsyncChannel.send` is `async` and suspends the producer until the element is consumed. `AsyncStream.Continuation.yield` is synchronous and can only buffer or drop.
</details>

## Check yourself
1. Is `throttle` a stable API in swift-async-algorithms 1.1.7?
2. How do you multicast an `AsyncStream` to several consumers?
3. What's the async equivalent of `AnyCancellable`?

<details><summary>Answers</summary>

1. No. It's `_throttle` (underscored).
2. Use `.share()` from AsyncAlgorithms, or create one stream per subscriber.
3. A `Task` handle: call `cancel()` on it, or let a structured scope like `.task` own it.
</details>

## Further reading
- swift-async-algorithms: https://github.com/apple/swift-async-algorithms. Per-operator guides are in `Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/`, and the package has its own `Evolution/` proposals.
