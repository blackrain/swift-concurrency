# 3.4 Swift 6.2 "Approachable Concurrency": default isolation, `nonisolated(nonsending)`, `@concurrent`, isolated conformances

## Why it matters
In Swift 6.0, strict concurrency produced many errors in code that never actually ran concurrently. A typical case: an app's model and helper code, all used from the main thread, couldn't call an `async` helper without hopping off the main actor. Swift 6.2 introduced a set of features that make **single-threaded by default, concurrent by opt-in** the norm. In a new Xcode project, they're **already on**. You need to know exactly which ones are enabled in your project, because they change where code runs.

## Mental model

```
Before (Swift 6.0 semantics)             After (approachable settings)
───────────────────────────────          ─────────────────────────────────────────
unannotated code: nonisolated            unannotated code: @MainActor   (-default-isolation MainActor)
func f() async → global executor         func f() async → caller's actor (NonisolatedNonsendingByDefault)
background work: implicit, by accident   background work: explicit, with @concurrent
```

## Core content

### What's actually enabled (verified against Xcode 27.1)
| Mechanism | Compiler flag | Xcode setting | SwiftPM (`swiftSettings:`) |
|---|---|---|---|
| Default MainActor isolation (SE-0466) | `-default-isolation MainActor` | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | `.defaultIsolation(MainActor.self)` |
| nonisolated(nonsending) by default (SE-0461) | `-enable-upcoming-feature NonisolatedNonsendingByDefault` | on when `SWIFT_APPROACHABLE_CONCURRENCY = YES` | `.enableUpcomingFeature("NonisolatedNonsendingByDefault")` |
| Infer isolated conformances (SE-0470) | `-enable-upcoming-feature InferIsolatedConformances` | on when `SWIFT_APPROACHABLE_CONCURRENCY = YES` | `.enableUpcomingFeature("InferIsolatedConformances")` |

`SWIFT_APPROACHABLE_CONCURRENCY = YES` also turns on three features that are already part of the Swift 6 language mode: `DisableOutwardActorInference` (SE-0401), `GlobalActorIsolatedTypesUsability` (SE-0434) and `InferSendableFromCaptures` (SE-0418). (This is from the setting's description in Xcode's `Swift.xcspec`.) The SwiftPM spellings in the table were verified by building a package with `swift-tools-version: 6.2`.

**New Xcode 27.1 project templates** set `SWIFT_APPROACHABLE_CONCURRENCY = YES` and, for app targets, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. They also set `SWIFT_VERSION = 5.0`. **A new Swift package gets none of these** unless you add them.

### 1. Default MainActor isolation (SE-0466)
With `-default-isolation MainActor`, every declaration in the module **that has no other isolation** is inferred to be `@MainActor`. Exceptions, listed in SE-0466 and verified where marked:
- declarations with explicit isolation (`nonisolated`, `@concurrent`, another global actor);
- declarations that infer isolation from a superclass, an override, a protocol conformance, or the enclosing type;
- everything inside an `actor`;
- declarations whose primary definition directly conforms to a protocol that inherits `SendableMetatype`. Verified: `enum Keys: CodingKey` stays **nonisolated**, as does `struct Packet: Wire` where `nonisolated protocol Wire: Sendable`.

Two subtleties that the proposal text doesn't make obvious, both verified with 6.4:
- A protocol declared **in the same MainActor-default module** is itself inferred `@MainActor`. Conforming to `protocol Wire: Sendable` therefore makes the type `@MainActor`, unless you write `nonisolated protocol Wire: Sendable`.
- Conforming **directly** to `Sendable` (`struct Point: Sendable`) does **not** make the type nonisolated. Its methods were still main-actor-isolated.

<!-- check: lib -->
<!-- check: flags -default-isolation MainActor -->
<!-- check: error "main actor-isolated global function 'helper()' cannot be called from outside of the actor" -->
```swift
func helper() {}                          // inferred @MainActor

nonisolated struct Parser {               // explicitly opted out: usable anywhere
    func parse(_ s: String) -> Int { s.count }
}

@concurrent func backgroundWork() async {
    _ = Parser().parse("ok")              // ✅
    helper()                              // ❌ main actor-isolated
}
```

### 2. `nonisolated(nonsending)` by default (SE-0461)
Without the feature, a nonisolated `async` function **always hops to the global executor**. With it, the function **runs on the caller's actor**. I measured both (the code is in [1.1](../01-async-await/01-async-functions.md) and [3.3](03-isolation-domains.md)): called from `@MainActor`, the unannotated `async` function ran on a background thread without the feature and on the main thread with it.

Why it matters:
1. **Non-`Sendable` values can be passed freely** to async helpers. In [3.3](03-isolation-domains.md), `await appendAsync(self.log)` was an error without the feature (*"sending main actor-isolated 'self.log' to @concurrent global function…"*) and compiled cleanly with it.
2. **Sync and async functions behave alike.** A sync nonisolated function always ran on the caller's actor. Now async ones do too.

The explicit spellings, which you can use regardless of the default:

<!-- check: lib -->
```swift
nonisolated(nonsending) func stayOnCaller() async {}   // runs on the caller's actor (or nonisolated if the caller is)
@concurrent func runInBackground() async {}            // always runs on the global concurrent executor
```

### 3. `@concurrent`: background work, made explicit
`@concurrent` is how you ask for "run this off the caller's actor". Verified rules:
- It applies only to `async` functions: `cannot use @concurrent on non-async global function 'notAsync()'`.
- It can't be combined with a global actor: `global function 'g()' has multiple actor-isolation attributes (@MainActor and @concurrent)`.
- Its parameters and results cross an isolation boundary, so non-`Sendable` arguments must be in a disconnected region ([4.2](../04-sendable-and-safety/02-region-isolation.md)).

<!-- check: lib -->
<!-- check: flags -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -->
```swift
import Foundation

struct Thumbnail: Sendable { let bytes: Int }

final class Gallery {                                      // @MainActor by default
    var thumbnails: [Thumbnail] = []

    func refresh(_ urls: [URL]) async {
        for url in urls {
            let t = await Self.render(url)                 // hop off the main actor…
            thumbnails.append(t)                           // …and back: main-actor state, no await needed
        }
    }

    @concurrent
    nonisolated static func render(_ url: URL) async -> Thumbnail {
        Thumbnail(bytes: url.absoluteString.count)         // heavy work here
    }
}
```

> Why does `render` say `nonisolated` as well as `@concurrent`? Because `Gallery` is `@MainActor` (by default isolation), its members inherit that isolation. `@concurrent` asks for the global executor, and `nonisolated` removes the inherited main-actor isolation. On a nonisolated type, `@concurrent` alone is enough.

### 4. Isolated conformances (SE-0470)
A `@MainActor` type can now satisfy a nonisolated protocol by declaring the conformance itself as main-actor-isolated. The compiler then prevents that conformance from being used off the main actor:

<!-- check: lib -->
<!-- check: error "main actor-isolated conformance of 'Banner' to 'Greeter' cannot be used in @concurrent context" -->
```swift
protocol Greeter { func greet() -> String }

@MainActor final class Banner {}
extension Banner: @MainActor Greeter {                       // isolated conformance
    func greet() -> String { "hi" }
}

func useAnywhere<G: Greeter>(_ g: G) -> String { g.greet() }

@MainActor func onMain(_ b: Banner) -> String { useAnywhere(b) }          // ✅
@concurrent func offMain(_ b: Banner) async -> String { useAnywhere(b) }  // ❌
```

Without isolated conformances, the only options were `nonisolated` witnesses (which can't touch main-actor state) or `@preconcurrency` conformances (which only add runtime checks).

**`InferIsolatedConformances`** makes `@MainActor` the *default* for conformances of `@MainActor` types. This causes the most common surprise with default MainActor isolation: **`Codable` becomes main-actor-only.** In a module built with `-default-isolation MainActor` (verified, even without the explicit upcoming-feature flag, as SE-0470 recommends for such modules):

<!-- check: lib -->
<!-- check: flags -default-isolation MainActor -->
<!-- check: error "main actor-isolated conformance of 'Item' to 'Decodable' cannot be used in @concurrent context" -->
```swift
import Foundation

struct Item: Codable { var name: String }                  // @MainActor type, @MainActor conformance

@concurrent func decodeInBackground(_ data: Data) async throws -> Item {
    try JSONDecoder().decode(Item.self, from: data)        // ❌ [#IsolatedConformances]
}
```

Two verified fixes:

<!-- check: lib -->
<!-- check: flags -default-isolation MainActor -->
```swift
import Foundation

nonisolated struct ItemA: Codable { var name: String }     // fix 1: the whole type is nonisolated

struct ItemB { var name: String }
extension ItemB: nonisolated Codable {}                    // fix 2: only the conformance is nonisolated

@concurrent func decode(_ data: Data) async throws -> (ItemA, ItemB) {
    (try JSONDecoder().decode(ItemA.self, from: data), try JSONDecoder().decode(ItemB.self, from: data))
}
```

**Rule of thumb for MainActor-by-default modules:** mark plain data types (DTOs, models decoded off the main thread, value types used by background work) as `nonisolated`.

### Migrating to `NonisolatedNonsendingByDefault`
Turning the feature on changes **runtime behavior**: code that used to run in the background now runs on the caller's actor, and on the main actor that can cause hangs. Use the migration mode (SE-0486) first:

```
-enable-upcoming-feature NonisolatedNonsendingByDefault:migrate
```

Xcode exposes the same option as the value `MIGRATE` for `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT`. Verified 6.4 output:

```
warning: feature 'NonisolatedNonsendingByDefault' will cause nonisolated async global function 'fetch'
         to run on the caller's actor; use '@concurrent' to preserve behavior [#NonisolatedNonsendingByDefault]
```

For each warning, decide whether the function does CPU-heavy or blocking work (mark it `@concurrent` to keep the old behavior) or is just glue code (let it follow its caller).

## Pitfalls & compiler errors
| Diagnostic | Cause | Fix |
|---|---|---|
| `main actor-isolated conformance of 'X' to 'P' cannot be used in @concurrent context [#IsolatedConformances]` | an isolated conformance (often an inferred `Codable`) is used off-main | `nonisolated` on the type or on the conformance |
| `main actor-isolated … cannot be called from outside of the actor` in a MainActor-default module | a helper you meant to be universal got `@MainActor` | mark it `nonisolated` |
| `cannot use @concurrent on non-async …` | `@concurrent` on a sync function | make it `async`, or drop the attribute |
| `multiple actor-isolation attributes (@MainActor and @concurrent)` | conflicting isolation | pick one; for members of `@MainActor` types, use `@concurrent nonisolated` |

- **Mixing modules with different defaults.** A library built with nonisolated default and an app built with MainActor default both behave correctly, but reading code requires knowing each module's settings. Document the settings in your README.
- **Turning on `NonisolatedNonsendingByDefault` and getting UI hitches.** Former "accidentally background" work now runs on the main actor. Find it with the `:migrate` warnings, and with Instruments ([7.4](../07-internals/04-performance-debugging.md)).

## Under the hood
- Default isolation is a purely **compile-time inference** rule. The binary contains whatever explicit isolation resulted from it.
- `nonisolated(nonsending)` passes the caller's isolation as an implicit parameter ([3.3](03-isolation-domains.md)). `@concurrent` functions don't take it. They hop to the global executor (or the task's executor preference, [7.2](../07-internals/02-executors.md)) on entry.
- An isolated conformance is checked statically where possible. For **dynamic casts** (`value as? any Equatable`), the runtime "will check whether the code is running on the executor associated with the conformance's isolation". If it isn't, the cast **fails and produces `nil`** (SE-0470, *Proposed solution* and *Data-race safety issues*).

## Exercises
1. Take a module with `-default-isolation MainActor`. Write a `nonisolated struct APIClient` with an `async throws` method that decodes JSON off the main actor, and call it from a `@MainActor` view model.
2. Under `NonisolatedNonsendingByDefault`, write a function that **must** run in the background (image resizing). Show the annotation.
3. Explain why `extension Model: @MainActor Equatable` might be a bad idea if you put `Model`s in a `Set` on a background actor.

<details><summary>Solutions</summary>

<!-- check: lib -->
<!-- check: flags -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -->
```swift
import Foundation

nonisolated struct User: Decodable, Sendable { let name: String }

nonisolated struct APIClient {
    @concurrent
    func fetchUser(from data: Data) async throws -> User {
        try JSONDecoder().decode(User.self, from: data)            // runs on the global executor
    }
}

final class ProfileModel {                                          // @MainActor by default
    var name = ""
    let client = APIClient()
    func load(_ data: Data) async {
        if let user = try? await client.fetchUser(from: data) { name = user.name }
    }
}

nonisolated enum ImageOps {
    @concurrent static func resize(_ pixels: [UInt8]) async -> [UInt8] { pixels.reversed() }
}
```
3. `Set` needs `Hashable`, which refines `Equatable`. With main-actor-isolated conformances, using the `Set` from a background actor is rejected at compile time (`#IsolatedConformances`). Generic code that discovers the conformance through `as? any Hashable` off the main actor gets `nil` back, and silently takes the fallback path. Make the conformance `nonisolated` if the type is pure data.
</details>

## Check yourself
1. Does `-swift-version 6` alone enable `NonisolatedNonsendingByDefault`?
2. In a MainActor-default module, is `enum CodingKeys: CodingKey` main-actor-isolated?
3. Why does `@concurrent` on a member of a `@MainActor` class need `nonisolated` too?

<details><summary>Answers</summary>

1. No. In 6.4 it's an upcoming feature for a *future* language mode (`Features.def`: `MIGRATABLE_UPCOMING_FEATURE(NonisolatedNonsendingByDefault, 461, LanguageMode::future)`).
2. No. `CodingKey` inherits `Sendable`, which inherits `SendableMetatype`, so conformers are inferred nonisolated (verified).
3. Members inherit the class's `@MainActor`. `nonisolated` removes that, and `@concurrent` then selects the global executor.
</details>

## Further reading
- SE-0461 *Run nonisolated async functions on the caller's actor by default*
- SE-0466 *Control default actor isolation inference* (including its amendment)
- SE-0470 *Global-actor isolated conformances*
- SE-0486 *Migration tooling for Swift features*
- Swift vision document: *Improving the approachability of data-race safety*
