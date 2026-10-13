# 5.4 Observation and concurrency: `@Observable`, `Observations`, and observation tracking

## Why it matters
`@Observable` (Swift 5.9, SE-0395) is how app state is modeled today, and SwiftUI tracks it automatically. Outside SwiftUI, for example in a view model reacting to a settings change or a service syncing state, you need to observe changes from **async code**. Swift 6.2 added `Observations`, an `AsyncSequence` of a model's values. Swift 6.4 added lower-level tracking APIs. All three have different timing semantics, and those semantics matter.

## Mental model

| API | Shape | When it fires | Availability (6.4 SDK) |
|---|---|---|---|
| `withObservationTracking(_:onChange:)` | one-shot callback | **once**, on the first **willSet** | macOS 14 / iOS 17 |
| `Observations { … }` (SE-0475) | `AsyncSequence` | the initial value, then **transactionally coalesced** new values | `anyAppleOS 26.0` |
| `withObservationTracking(options:_:onChange:)` (SE-0506) | one-shot, with options (`.willSet`, `.didSet`, `.deinit`) | the chosen event kinds | `anyAppleOS 27.0` |
| `withContinuousObservation(options:apply:)` (SE-0506) | repeating callback + `Token` | the initial event, then each chosen event | `anyAppleOS 27.0` |

## Core content

### `Observations`: the async sequence you'll usually want

<!-- check: output "Observations saw: [0, 2, 3]" -->
```swift
import Observation

@Observable @MainActor final class Settings { var volume = 0 }

@MainActor func run() async {
    let settings = Settings()
    let watcher = Task {
        var seen: [Int] = []
        for await v in Observations({ settings.volume }) {
            seen.append(v)
            if seen.count == 3 { break }
        }
        return seen
    }
    try? await Task.sleep(for: .milliseconds(20))
    settings.volume = 1
    settings.volume = 2                                  // same synchronous turn as `= 1`
    try? await Task.sleep(for: .milliseconds(20))
    settings.volume = 3
    print("Observations saw:", await watcher.value)
}

await run()
```

The verified output is `[0, 2, 3]`:
- **The initial value is emitted** (`0`).
- **Changes are transactional.** `1` and `2` were written in the same synchronous stretch, so the sequence emitted only `2`. The sequence re-evaluates the closure after the change completes, so you never see torn intermediate states of several properties.
- The closure can read **several properties** (`Observations { (model.a, model.b) }`), and it re-fires when any of them changes.
- **Initializer (6.4 SDK):** `init(@_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Element)`. The closure inherits the actor context, so it runs on the main actor here, and `Element` must be `Sendable`.
- `Observations.untilFinished { … }` returns `.next(value)` or `.finish` to end the sequence from inside the closure.

### `withObservationTracking`: the classic one-shot (verified)
<!-- check: output "classic fired times: 1" -->
```swift
import Observation
import Synchronization

@Observable final class Model: @unchecked Sendable { var count = 0 }   // @unchecked only for the demo

let m = Model()
let fired = Atomic<Int>(0)
withObservationTracking {
    _ = m.count                                          // reads inside `apply` are tracked
} onChange: {
    fired.add(1, ordering: .relaxed)
    print("classic onChange, value still:", m.count)     // prints 0: willSet semantics
}
m.count = 1
m.count = 2
print("classic fired times:", fired.load(ordering: .relaxed))
```

The output is `value still: 0`, then `classic fired times: 1`. **It fires once, before the value changes.** To keep observing, you have to re-register inside `onChange`. That's the pattern SwiftUI uses internally, and it's why `Observations` exists.

### Swift 6.4: options and continuous tracking (SE-0506, OS 27+)
<!-- check: output "didSet event kind: true value now: 3" -->
```swift
import Observation

@Observable final class Model: @unchecked Sendable { var count = 0 }

func demo() async throws {
    let m = Model()
    withObservationTracking(options: [.didSet]) {
        _ = m.count
    } onChange: { event in
        print("didSet event kind:", event.kind == .didSet, "value now:", m.count)   // sees the NEW value
    }
    m.count = 3

    let token = withContinuousObservation(options: [.didSet]) { event in
        print("continuous:", event.kind == .initial ? "initial" : "didSet", m.count)
    }
    m.count = 4
    try await Task.sleep(for: .milliseconds(50))
    m.count = 5
    try await Task.sleep(for: .milliseconds(50))
    token.cancel()                                       // `Token` is ~Copyable; cancel() consumes it
    m.count = 6                                          // not observed
    try await Task.sleep(for: .milliseconds(50))
}

try await demo()
```

The verified output is `didSet event kind: true value now: 3`, then `continuous: initial 4`, then `continuous: didSet 5`. Nothing was printed for `6`. Note that the **initial** callback ran *after* `m.count = 4`. Its `apply` closure is `@isolated(any)` and is scheduled, not called synchronously.

> **Proposal vs. SDK:** SE-0506's text names the continuous API `withContinuousObservationTracking`. The Swift 6.4 SDK ships it as **`withContinuousObservation(options:apply:) -> ObservationTracking.Token`**. This guide uses the shipped name.

### Observing from a view model: a complete pattern
<!-- check: lib -->
```swift
import Observation

@Observable @MainActor final class AppSettings { var useMetric = true }

@MainActor final class WeatherModel {
    private(set) var display = ""
    private var observation: Task<Void, Never>?

    func start(settings: AppSettings) {
        observation = Task { [weak self] in
            for await metric in Observations({ settings.useMetric }) {
                self?.display = metric ? "21 °C" : "70 °F"
            }
        }
    }

    func stop() { observation?.cancel() }
}
```

## Pitfalls & compiler errors
- **`withObservationTracking` called once, expecting continuous updates.** It's one-shot.
- **Reading a property in `onChange` and expecting the new value** with the classic API. You get the old value (willSet).
- **Ignoring availability.** `Observations` needs OS 26, and the 6.4 additions need OS 27. Older targets need the re-registration loop.
- **`Element` must be `Sendable`.** Observe a `Sendable` projection of the model (a struct of values), not the model object itself.
- **Strong `self` in a long-lived observation task** keeps the view model alive. Use `[weak self]`, or cancel the task.

## Under the hood
- The `@Observable` macro generates an `ObservationRegistrar` and wraps each stored property's accessors so that reads register *access* (when tracking is active) and writes send `willSet`/`didSet`.
- Tracking works through a **thread-local** "current access list" (`_ThreadLocal` holding an `ObservationTracking._AccessList`, in `stdlib/public/Observation/Sources/Observation/ObservationRegistrar.swift`). It's active while `apply` runs synchronously. That's why only the properties you **read inside the closure** are tracked, and why `apply` must be synchronous.
- `Observations` coalesces changes by re-running the closure in the observer's isolation after a change, rather than delivering each mutation (SE-0475, *transactional*).

## Exercises
1. Observe two properties together (`firstName`, `lastName`) and emit a full name. Prove that updating both in one synchronous block yields a single emission.
2. On an iOS 17 deployment target (no `Observations`), write an `AsyncStream`-based equivalent using `withObservationTracking` with re-registration.
3. Explain why `Observations` emits the initial value, but `withObservationTracking`'s `onChange` doesn't.

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
import Observation

@Observable @MainActor final class Person { var first = "A"; var last = "B" }

@MainActor func fullNames(_ p: Person) -> some AsyncSequence<String, Never> {
    Observations { "\(p.first) \(p.last)" }
}

@MainActor final class LegacyObserver {                 // @MainActor class: Sendable, safe to capture
    private let person: Person
    private let continuation: AsyncStream<String>.Continuation
    let stream: AsyncStream<String>

    init(_ person: Person) {
        self.person = person
        (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        observe()
    }

    private func observe() {
        let value = withObservationTracking { "\(person.first) \(person.last)" } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }   // re-register after the change lands
        }
        continuation.yield(value)
    }
}
```
3. `Observations` is an async *sequence of values*: its first element is the current state. `withObservationTracking` is a change *notification*: `apply` already returned the current value synchronously, and `onChange` reports only changes.
</details>

## Check yourself
1. Does `withObservationTracking`'s `onChange` see the new value?
2. What does `Observations` emit when two properties change in the same synchronous block?
3. What's the 6.4 SDK name of SE-0506's continuous tracking function?

<details><summary>Answers</summary>

1. No. It's willSet. Use the 6.4 `options: [.didSet]` variant to see the new value.
2. One emission, with both new values (transactional).
3. `withContinuousObservation(options:apply:)`.
</details>

## Further reading
- SE-0395 *Observation*
- SE-0475 *Transactional Observation of Values*
- SE-0506 *Advanced Observation Tracking*
