# 5.1 `AsyncSequence`: values over time

## Why it matters
`async` functions return **one** value later. Many things produce **many** values over time: bytes from a network stream, notifications, sensor readings, UI events, database change feeds. `AsyncSequence` is `Sequence` with `await`: you consume it with `for await`, and you get cancellation, backpressure and structured lifetimes for free.

## Mental model

```
Sequence:       for x in seq        { }   next() -> Element?
AsyncSequence:  for await x in seq  { }   next() async throws(Failure) -> Element?
                                           ▲ suspends until the next value arrives; nil = finished
```

Pull-based: the **consumer** asks for the next element. Nothing is produced for a consumer that isn't asking, unless the source buffers ([5.2](02-asyncstream.md)).

## Core content

### Consuming

<!-- check: lib -->
```swift
import Foundation

func lines(of url: URL) async throws -> [String] {
    var result: [String] = []
    for try await line in url.lines {          // `try` because URL.AsyncLineSequence can fail
        if line.isEmpty { continue }
        if result.count == 100 { break }       // breaking ends the iteration and releases the source
        result.append(line)
    }
    return result
}
```

- `for await` (or `for try await`) calls `next()` repeatedly until it returns `nil` or throws.
- **Cancellation:** when the consuming task is cancelled, well-behaved sequences make `next()` return `nil` or throw `CancellationError`. With `AsyncStream`, cancellation ends the loop (verified in [5.2](02-asyncstream.md)).
- **Breaking out early** destroys the iterator, which lets the source clean up.

### Typed failures (SE-0421, Swift 6.0)
`AsyncSequence` and `AsyncIteratorProtocol` have a `Failure` associated type, and a `next(isolation:)` requirement, in the 6.4 SDK:

<!-- check: skip -->
```swift
public protocol AsyncIteratorProtocol<Element, Failure> {
  associatedtype Element
  @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
  associatedtype Failure: Error = any Error
  mutating func next() async throws -> Element?
  @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
  mutating func next(isolation actor: isolated (any Actor)?) async throws(Failure) -> Element?
}
```

This gives you three things:
- If `Failure == Never`, you write `for await`, with no `try`.
- You can return `some AsyncSequence<Int, Never>`, using primary associated types for both the element and the failure.
- `next(isolation:)` lets the iterator run in the caller's isolation, so non-`Sendable` iterators can be used from actors.

### Writing your own sequence

<!-- check: output "[6, 4, 2]" -->
```swift
struct Countdown: AsyncSequence {
    typealias Failure = Never
    let start: Int

    struct AsyncIterator: AsyncIteratorProtocol {
        var current: Int
        mutating func next() async -> Int? {
            guard current > 0 else { return nil }
            defer { current -= 1 }
            return current
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(current: start) }
}

func evens() -> some AsyncSequence<Int, Never> {
    Countdown(start: 6).filter { $0.isMultiple(of: 2) }
}

var out: [Int] = []
for await n in evens() { out.append(n) }      // no `try`: Failure == Never
print(out)
```

Verified output: `[6, 4, 2]`.

> **Deployment-target trap (verified):** compile the same file for `macOS 14` and you get `'Failure' is only available in macOS 15.0 or newer`, plus `for-in loop can throw, but is not marked with 'try'`. On older targets, `Failure` isn't available, so every `for await` over a generic or custom sequence is treated as throwing.

In practice, you'll rarely implement `AsyncIteratorProtocol` by hand. `AsyncStream` ([5.2](02-asyncstream.md)) covers most custom sources.

### Built-in operators
The standard library includes `map`, `compactMap`, `flatMap`, `filter`, `prefix(_:)`, `prefix(while:)`, `dropFirst(_:)`, `drop(while:)`, `contains`, `first(where:)`, `min`, `max`, `reduce`, and `allSatisfy`. The transform closures can be `async`. Since SE-0421, these operators propagate `Failure`: mapping a non-throwing sequence with a non-throwing closure keeps it non-throwing.

<!-- check: output "30 20 10" -->
```swift
struct Countdown: AsyncSequence {
    typealias Failure = Never
    let start: Int
    struct AsyncIterator: AsyncIteratorProtocol {
        var current: Int
        mutating func next() async -> Int? {
            guard current > 0 else { return nil }
            defer { current -= 1 }
            return current
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(current: start) }
}

var values: [String] = []
for await v in Countdown(start: 3).map({ $0 * 10 }) { values.append(String(v)) }
print(values.joined(separator: " "))
```

Time-based operators (`debounce`, `throttle`), and combining operators (`merge`, `combineLatest`, `zip`), live in the **swift-async-algorithms** package ([5.3](03-async-algorithms.md)).

### Sources you already have
- `URL.lines`, `URL.resourceBytes`, `FileHandle.bytes`, `URLSession.bytes(from:)`
- `NotificationCenter.default.notifications(named:)`
- `Observations` for `@Observable` models ([5.4](04-observation.md))

## Pitfalls & compiler errors
- **Iterating the same single-consumer sequence from two tasks.** Many sequences don't support it. `AsyncThrowingStream` traps (verified in [5.2](02-asyncstream.md)).
- **A `for await` loop that never ends** keeps its task alive forever. Tie it to a structured scope (for example, SwiftUI `.task`), or cancel it.
- `for-in loop can throw, but is not marked with 'try'` on a sequence you think is non-throwing: check your deployment target (see above).

## Under the hood
- `for await x in seq { body }` is lowered to: `var it = seq.makeAsyncIterator(); while let x = try await it.next(isolation: #isolation) { body }`. When `Failure` isn't available, it uses `next()`.
- Operators like `map` are lightweight structs that wrap the base sequence. No buffering or task creation happens. Everything runs in the consumer's task.

## Exercises
1. Write `struct Ticker: AsyncSequence` that yields an increasing `Int` every N milliseconds, forever, using `Task.sleep`. Make it stop when the consuming task is cancelled.
2. From `Countdown(start: 10)`, produce the first 3 odd numbers, squared.
3. Why can `Countdown.AsyncIterator.next()` be declared non-throwing while the protocol requirement is `async throws`?

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
struct Ticker: AsyncSequence {
    typealias Failure = Never
    let interval: Duration
    struct AsyncIterator: AsyncIteratorProtocol {
        let interval: Duration
        var count = 0
        mutating func next() async -> Int? {
            do { try await Task.sleep(for: interval) } catch { return nil }   // cancelled → finish
            count += 1
            return count
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(interval: interval) }
}

struct Countdown: AsyncSequence {
    typealias Failure = Never
    let start: Int
    struct AsyncIterator: AsyncIteratorProtocol {
        var current: Int
        mutating func next() async -> Int? {
            guard current > 0 else { return nil }
            defer { current -= 1 }
            return current
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(current: start) }
}

func oddSquares() async -> [Int] {
    var r: [Int] = []
    for await x in Countdown(start: 10).filter({ $0 % 2 == 1 }).map({ $0 * $0 }).prefix(3) { r.append(x) }
    return r                                                                  // [81, 49, 25]
}
```
3. A non-throwing function can satisfy a throwing requirement, just as a sync method can satisfy an `async` one ([1.4](../01-async-await/04-async-in-the-type-system.md)).
</details>

## Check yourself
1. Does `for await` over a `Failure == Never` sequence need `try`?
2. What happens to a `for await` loop when its task is cancelled?
3. Where do `debounce` and `merge` come from?

<details><summary>Answers</summary>

1. No, on deployment targets where `Failure` is available (macOS 15 / iOS 18 and later).
2. That depends on the sequence. Well-behaved ones finish (`nil`) or throw `CancellationError`. `AsyncStream` finishes.
3. The swift-async-algorithms package.
</details>

## Further reading
- SE-0298 *Async/Await: Sequences*
- SE-0421 *Generalize effect polymorphism for `AsyncSequence` and `AsyncIteratorProtocol`*
