# 5.2 `AsyncStream` and `AsyncThrowingStream`

## Why it matters
`AsyncStream` is the bridge from **push**-based sources (delegates, callbacks, `NotificationCenter`, KVO, timers) to `for await`. You'll write more `AsyncStream`s than custom `AsyncSequence`s. Most of the behavior that matters is in the details: buffering, termination, and how many consumers there are.

## Mental model

```
producer (any thread)                   buffer (policy)              consumer (one task)
continuation.yield(x)  ───────────────▶ [ … ] ────── next() ───────▶ for await x in stream
continuation.finish()                                                 loop ends
                        ◀─────────────  onTermination(reason)  ◀───── consumer cancelled / stream deinit / finish
```

The producer **never suspends**. `yield` is synchronous, and it returns immediately with a result that tells you what happened to the value.

## Core content

### Creating a stream: `makeStream` (SE-0388)

<!-- check: lib -->
```swift
import Foundation

final class Thermometer: @unchecked Sendable {   // stand-in for a delegate-based SDK object
    var onReading: (@Sendable (Double) -> Void)?
    func start() {}
    func stop() {}
}

func readings(from sensor: Thermometer) -> AsyncStream<Double> {
    let (stream, continuation) = AsyncStream.makeStream(of: Double.self,
                                                        bufferingPolicy: .bufferingNewest(1))
    sensor.onReading = { value in continuation.yield(value) }
    continuation.onTermination = { _ in sensor.stop() }   // runs when the consumer stops or is cancelled
    sensor.start()
    return stream
}
```

`makeStream` returns the stream and its continuation together. That's easier than the closure-based `AsyncStream { continuation in … }` initializer when you need to store the continuation.

### Buffering policies (verified)
In this experiment, five values were yielded before anyone consumed:

| Policy | Delivered | Result of `yield(5)` |
|---|---|---|
| `.unbounded` (default) | `[1, 2, 3, 4, 5]` | `enqueued(remaining: 9223372036854775807)` (`Int.max`) |
| `.bufferingNewest(2)` | `[4, 5]` | `dropped(3)`: the *oldest* buffered value was evicted |
| `.bufferingOldest(2)` | `[1, 2]` | `.dropped(5)`: the *new* value was rejected |

<!-- check: output "bufferingNewest(2) delivered: [4, 5]" -->
```swift
let (s1, c1) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(2))
for i in 1...5 {
    let r = c1.yield(i)
    if i == 5 { print("yield result for 5:", r) }      // dropped(3)
}
c1.finish()
var got: [Int] = []
for await v in s1 { got.append(v) }
print("bufferingNewest(2) delivered:", got)
```

Choose the policy deliberately:
- **UI state** (latest location, latest search query): `.bufferingNewest(1)`. Only the freshest value matters.
- **Events that must all be processed** (log lines, commands): `.unbounded`, but then a slow consumer means unbounded memory growth.
- `AsyncStream` has **no backpressure**: the producer can't wait for the consumer. (SE-0406, *Backpressure support for AsyncStream*, is "Returned for revision".) If you need backpressure, use `AsyncChannel` from swift-async-algorithms ([5.3](03-async-algorithms.md)).

### Termination (verified)
`onTermination` runs exactly once, when:
- the producer calls `finish()` (reason `.finished`),
- the consuming task is **cancelled** (reason `.cancelled`; the `for await` loop ends normally), or
- the stream is deallocated with no consumers left.

After termination, `yield` returns `.terminated` and drops the value.

<!-- check: output "onTermination: cancelled" -->
```swift
let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
continuation.onTermination = { reason in print("onTermination:", reason) }

let consumer = Task {
    for await _ in stream {}
    return "loop ended"
}
try await Task.sleep(for: .milliseconds(20))
consumer.cancel()
print(await consumer.value)                                  // "loop ended": no error is thrown
print("yield after termination:", continuation.yield(1))    // terminated
```

**Always use `onTermination` to unregister observers and stop hardware.** It's the stream's equivalent of `deinit`.

### How many consumers? (verified, and the two types differ)
- **`AsyncStream`**: several tasks can iterate the same stream. Each element goes to **one** of them, never to all. In my run, consumer A got `[1, 3, 5]` and B got `[2, 4, 6]`. It's not a broadcast. The storage keeps an array of waiting continuations.
- **`AsyncThrowingStream`**: a second concurrent `next()` **traps**: `Fatal error: attempt to await next() on more than one task` (from `AsyncStreamBuffer.swift`, verified, exit code 133).

If you need **multicast** (every subscriber sees every value), create one stream per subscriber and keep their continuations in a collection. `AsyncStream.Continuation` is `Sendable`, and `Hashable` since Swift 6.2 (SE-0468), so a `Set` works:

<!-- check: lib -->
```swift
actor Broadcaster<Value: Sendable> {
    private var continuations: [UInt64: AsyncStream<Value>.Continuation] = [:]
    private var nextID: UInt64 = 0

    func subscribe() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
        let id = nextID; nextID += 1
        continuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.remove(id) } }
        return stream
    }

    func send(_ value: Value) {
        for c in continuations.values { c.yield(value) }
    }

    private func remove(_ id: UInt64) { continuations[id] = nil }
}
```

### `AsyncThrowingStream`
It's the same API, plus `finish(throwing:)`. The consumer's `for try await` rethrows the error. Use it for sources that can fail, such as a socket.

### Pull-based streams: `AsyncStream(unfolding:)`
<!-- check: lib -->
```swift
func pages(fetch: @escaping @Sendable (Int) async -> [String]?) -> AsyncStream<[String]> {
    let counter = Counter()
    return AsyncStream(unfolding: {
        let page = await counter.next()
        return await fetch(page)                 // return nil to finish
    })
}

actor Counter { private var n = 0; func next() -> Int { defer { n += 1 }; return n } }
```

The closure runs only when the consumer asks for the next value, so it has natural backpressure.

## Pitfalls & compiler errors
- **Forgetting `finish()`**: the consumer waits forever.
- **No `onTermination`**: observers and sensors keep running after the consumer is gone.
- **Retain cycles**: an `onTermination` closure that captures the object that owns the continuation. Use `[weak self]`, or capture only what's needed.
- **Assuming multicast semantics.** `AsyncStream` splits elements among consumers. It doesn't duplicate them.
- **Unbounded buffering with a fast producer** grows memory without limit.

## Under the hood
- The stream's storage is a lock-protected buffer (`_Deque`) plus waiting continuations (`AsyncStreamBuffer.swift`). `yield` either resumes a waiting consumer directly or appends to the buffer. That's why `yield` is synchronous and callable from any thread.
- `AsyncStream.Continuation` is `Sendable`. You can call `yield` from any isolation domain, and it's thread-safe.

## Exercises
1. Wrap `NotificationCenter` observation of a custom notification as `AsyncStream<Void>` (manual observer + `onTermination` removing it). Then compare it with the built-in `NotificationCenter.default.notifications(named:)`.
2. Build a `debounced(_:)` stream transformer by hand: forward a value only if no new value arrives within 300 ms. (Then see [5.3](03-async-algorithms.md) for the library version.)
3. Explain what happens if two SwiftUI views both iterate the same `AsyncStream` from your model.

<details><summary>Solutions</summary>

The observer token (`any NSObjectProtocol`) isn't `Sendable`, but `onTermination` is a `@Sendable` closure. Rather than reaching for `nonisolated(unsafe)`, move the token into a `Mutex`, which is `Sendable` for any value ([4.3](../04-sendable-and-safety/03-unchecked-mutex-atomics.md)):

<!-- check: output "received 2" -->
```swift
import Foundation
import Synchronization

extension Notification.Name { static let didSync = Notification.Name("didSync") }

final class ObserverBox: Sendable {
    private let token: Mutex<(any NSObjectProtocol)?>
    init(_ t: sending any NSObjectProtocol) { token = Mutex(t) }
    func remove() {
        token.withLock { t in
            if let t { NotificationCenter.default.removeObserver(t) }
            t = nil
        }
    }
}

func syncEvents() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    let token = NotificationCenter.default.addObserver(forName: .didSync, object: nil, queue: nil) { _ in
        continuation.yield()
    }
    let box = ObserverBox(token)
    continuation.onTermination = { _ in box.remove() }
    return stream
}

let events = syncEvents()
let listener = Task { var n = 0; for await _ in events { n += 1; if n == 2 { break } }; return n }
try await Task.sleep(for: .milliseconds(20))
NotificationCenter.default.post(name: .didSync, object: nil)
NotificationCenter.default.post(name: .didSync, object: nil)
print("received", await listener.value)
```
3. They compete: each element goes to only one of them. Give each view its own stream (the multicast pattern), or observe an `@Observable` model instead ([5.4](04-observation.md)).
</details>

## Check yourself
1. Does `continuation.yield` ever suspend the producer?
2. What does `.bufferingNewest(1)` do when three values arrive before the consumer reads one?
3. What happens to a `for await` loop over an `AsyncStream` when its task is cancelled?

<details><summary>Answers</summary>

1. No. It's synchronous.
2. It keeps only the latest one. The earlier ones are dropped, and `yield` reports `.dropped(old)`.
3. The loop ends (`next()` returns `nil`), and `onTermination` runs with `.cancelled`.
</details>

## Further reading
- SE-0314 *`AsyncStream` and `AsyncThrowingStream`*
- SE-0388 *Convenience `Async[Throwing]Stream.makeStream` methods*
- SE-0406 *Backpressure support for AsyncStream* (returned for revision)
- SE-0468 *`Hashable` conformance for `Async(Throwing)Stream.Continuation`*
