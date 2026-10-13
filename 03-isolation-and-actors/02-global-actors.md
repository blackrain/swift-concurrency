# 3.2 Global actors and `@MainActor`

## Why it matters
An actor instance protects the state *inside one object*. A **global actor** is a single, program-wide actor that can protect state spread across *many* types, functions and globals. `@MainActor` is the one you use every day: it ties UI code to the main thread, and the compiler checks it.

## Mental model

```
@MainActor ─────────────┐  one serial executor (the main thread / main queue)
  class ViewModel       │
  func updateUI()       │  all of these share ONE isolation domain:
  var appState: State   │  they can call each other synchronously
  struct Screen: View   ┘
```

A global actor is an **annotation that names a shared isolation domain**. Everything annotated with it can access everything else in that domain without `await`.

## Core content

### Declaring and using a global actor

<!-- check: lib -->
```swift
@globalActor
actor DatabaseActor {
    static let shared = DatabaseActor()
}

@DatabaseActor
final class Repository {
    private var rows: [Int] = []
    func insert(_ r: Int) { rows.append(r) }
    func all() -> [Int] { rows }
}

@DatabaseActor
func migrate(_ repo: Repository) {
    repo.insert(1)                         // same domain: synchronous
}

func client(_ repo: Repository) async {
    await repo.insert(2)                   // from outside: await
    let rows = await repo.all()
    print(rows)
}
```

A global actor is any type marked `@globalActor` that has a `static let shared` instance of an actor type. Use custom global actors sparingly. They're appropriate for one subsystem whose state is spread across several types, such as a database layer. For a single object, a plain `actor` is simpler.

### What gets inferred (verified with Swift 6.4)
Isolation propagates in several ways, and each one below was confirmed with the compiler:

<!-- check: lib -->
<!-- check: error "call to main actor-isolated instance method 'helper()' in a synchronous nonisolated context" -->
```swift
@MainActor protocol Screen { func render() }

struct Home: Screen {                      // conformance in the PRIMARY declaration…
    func render() {}
    func helper() {}                       // …makes the whole type @MainActor, including helper()
}

struct Settings { func helper() {} }       // stays nonisolated…
extension Settings: Screen {               // …conformance in an EXTENSION isolates only that extension
    func render() {}
}

@MainActor class Base { func a() {} }
class Derived: Base { func b() {} }        // subclasses inherit the global actor

func probe(h: Home, s: Settings, d: Derived) {
    h.helper()     // ❌ main actor-isolated
    s.helper()     // ✅ nonisolated
}
```

| Source | Inferred isolation |
|---|---|
| `@MainActor` on a type | all its members (except `nonisolated` ones, and `let`s accessed in-module, see [3.5](05-nonisolated-and-escape-hatches.md)) |
| a subclass of a global-actor class | the same global actor |
| a conformance to a global-actor protocol **in the primary declaration** | the whole type |
| a conformance to a global-actor protocol **in an extension** | only the members in that extension |
| an override of a global-actor method | the same global actor |
| property wrappers | **no longer** inferred in Swift 6 (SE-0401). `@StateObject` and friends don't make a type `@MainActor` any more |
| the module's default isolation (`-default-isolation MainActor`) | everything unannotated in the module ([3.4](04-approachable-concurrency.md)) |

> In the current SDK, SwiftUI declares `@preconcurrency @MainActor public protocol View` (verified in the macOS 27 SDK's `SwiftUICore.swiftinterface`). That's why a `struct MyView: View` is main-actor-isolated: by the primary-declaration conformance rule above. The `@preconcurrency` keeps clients in older language modes source-compatible.

### Global-actor-isolated types are `Sendable`
A `@MainActor` (or any global-actor) class can be passed freely between isolation domains. Every access to its state is guarded by the actor anyway. The compiler accepted `let x: any Sendable = repo` for a `@DatabaseActor final class` without complaint (verified). This is what makes the common pattern of passing a `@MainActor` view model around work.

### Hopping to the main actor

<!-- check: lib -->
```swift
@MainActor final class Model { var status = "" }

@concurrent func backgroundWork(model: Model) async {
    let result = "done"                              // heavy work here, off the main actor
    await MainActor.run { model.status = result }    // option 1: a closure
    await setStatus(model, result)                   // option 2 (usually cleaner): call a @MainActor function
}

@MainActor func setStatus(_ model: Model, _ s: String) { model.status = s }
```

Prefer annotating functions with `@MainActor` over sprinkling `MainActor.run` calls around. Functions are reusable, and they document the requirement in the type system.

### Closures with global-actor isolation
<!-- check: lib -->
```swift
func onEvent(_ handler: @escaping @MainActor @Sendable () -> Void) {}

@MainActor final class Controller {
    var count = 0
    func setUp() {
        onEvent { self.count += 1 }           // the closure is @MainActor: synchronous access to main-actor state
        Task { @MainActor in self.count += 1 } // explicit isolation for a Task closure
    }
}
```

A closure type annotated `@MainActor` can only be *called* on the main actor, so its body can touch main-actor state.

### Global and static variables
In Swift 6, every global and static `var` must be protected: give it a global actor, make it a `let` of a `Sendable` type, or explicitly opt out:

<!-- check: lib -->
```swift
@MainActor var currentTheme = "light"          // ✅ isolated
let maxRetries = 3                             // ✅ immutable and Sendable
nonisolated(unsafe) var legacyCounter = 0      // ⚠️ an opt-out: you guarantee the safety yourself
```

The error for an unprotected global is `var '…' is not concurrency-safe because it is nonisolated global shared mutable state [#MutableGlobalVariable]` (see [0.1](../00-foundations/01-threads-queues-parallelism.md)).

## Pitfalls & compiler errors
- `call to main actor-isolated instance method '…' in a synchronous nonisolated context [#ActorIsolatedCall]`: either make the caller `@MainActor`, or make it async and `await` the call.
- **Surprise isolation from a protocol conformance.** Conforming a model type to a `@MainActor` protocol in its primary declaration makes *everything* in it `@MainActor`. Put the conformance in an extension to limit its effect.
- **Overusing custom global actors.** Each one is a serial bottleneck, and crossing between them costs a hop. One per subsystem at most.
- **Assuming `@MainActor` code runs instantly.** A `Task { @MainActor in … }` is *enqueued*, and the main actor may be busy.

## Under the hood
- `@globalActor` means the compiler routes the isolation of everything annotated `@X` to `X.shared`'s executor.
- On Apple platforms, main-actor jobs are enqueued on the **main dispatch queue** (`swift_dispatchEnqueueMain` in `DispatchGlobalExecutor.cpp` calls `dispatchEnqueue(dispatch_get_main_queue(), job, …)`), at the job's priority as QoS. That's why main-actor jobs and `DispatchQueue.main.async` blocks share one queue, and the main run loop drains both.
- Inference rules are applied at compile time. At runtime, the compiler inserts executor *hops* only at isolation boundaries (calls that need `await`).

## Exercises
1. Create a `@globalActor actor AudioActor`. Isolate an `AudioEngine` class and an `AudioMixer` class to it, and show that they can call each other synchronously.
2. A `struct Profile: ObservableModel` (a `@MainActor` protocol) has a `static func decode(_ data: Data) -> Profile` that background code needs to call. Restructure it so `decode` isn't main-actor-isolated.
3. Why is a `@MainActor final class` `Sendable`, while a plain `final class` with a `var` isn't?

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
import Foundation

@globalActor actor AudioActor { static let shared = AudioActor() }

@AudioActor final class AudioMixer { func mix() {} }
@AudioActor final class AudioEngine {
    let mixer = AudioMixer()
    func render() { mixer.mix() }                 // same global actor: synchronous
}

@MainActor protocol ObservableModel {}

struct Profile { var name: String }               // primary declaration stays nonisolated
extension Profile: ObservableModel {}             // the conformance doesn't infer isolation onto the type's own members
extension Profile {
    static func decode(_ data: Data) -> Profile { Profile(name: String(decoding: data, as: UTF8.self)) }
}

func background(_ d: Data) async -> Profile { Profile.decode(d) }   // ✅ no hop needed
```
3. Every access to a `@MainActor` class's mutable state is isolated to the main actor, so sharing the reference can't cause a data race. A plain class's `var` could be accessed from two threads at once.
</details>

## Check yourself
1. `class B: A` where `A` is `@MainActor`. Is `B` main-actor-isolated?
2. `extension Item: Screen {}` where `Screen` is a `@MainActor` protocol. Are `Item`'s other methods main-actor-isolated?
3. What's the difference between `@MainActor func f()` and `func f() { MainActor.assumeIsolated { … } }`?

<details><summary>Answers</summary>

1. Yes. Subclasses inherit global-actor isolation.
2. No. Only the members declared in that extension are.
3. The first is checked statically: callers must be on the main actor or `await`. The second has no static protection. It traps at runtime if it's called off the main actor ([3.5](05-nonisolated-and-escape-hatches.md)).
</details>

## Further reading
- SE-0316 *Global actors*
- SE-0401 *Remove Actor Isolation Inference caused by Property Wrappers*
- SE-0412 *Strict concurrency for global variables*
- SE-0434 *Usability of global-actor-isolated types*
