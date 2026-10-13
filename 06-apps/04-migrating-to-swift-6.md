# 6.4 Migrating an app to Swift 6

## Why it matters
Most real codebases started before Swift 6. Turning on the Swift 6 language mode for a large target at once can produce hundreds of errors, and fixing them blindly (`@MainActor` everywhere, `@unchecked Sendable` everywhere) creates hitches and hides races. A staged migration keeps the app shippable throughout, and produces a codebase whose isolation is actually designed.

## Mental model

```
Stage 0  Swift 5 mode, minimal checking         (today)
Stage 1  Swift 5 mode + complete checking       → everything shows up as WARNINGS
Stage 2  fix leaf modules first (models, utilities, networking), then upward
Stage 3  per-target Swift 6 mode                → the warnings become ERRORS, target by target
Stage 4  adopt approachable features deliberately (default isolation, nonsending), using :migrate
```

The language mode is **per target** (SE-0435), so modules can migrate independently. A Swift 6 module can depend on a Swift 5 module, and vice versa.

## Core content

### Stage 1: see everything as warnings
| | Xcode | SwiftPM (`swiftSettings:`) | Compiler |
|---|---|---|---|
| complete checking in Swift 5 mode | `SWIFT_STRICT_CONCURRENCY = complete` | `.enableUpcomingFeature("StrictConcurrency")` | `-strict-concurrency=complete` |
| Swift 6 mode | `SWIFT_VERSION = 6` | `.swiftLanguageMode(.v6)` (verified) | `-swift-version 6` |

Xcode's `Swift.xcspec` describes `SWIFT_STRICT_CONCURRENCY` as "always 'complete' when in the Swift 6 language mode and produces errors instead of warnings". So in Swift 5 mode, `complete` gives you the full list of problems as warnings, without breaking the build.

### Stage 2: fix from the bottom up
1. **Leaf modules first** (models, utilities). Their fixes, such as `Sendable` conformances on value types, remove errors in every module above them.
2. **Make value types `Sendable`.** Internal structs are inferred automatically. Public ones need an explicit conformance ([4.1](../04-sendable-and-safety/01-sendable-and-sending.md)).
3. **Give each class an isolation story.** For each one, decide:
   - UI state → `@MainActor`
   - shared mutable service → `actor`
   - immutable → `final class: Sendable`
   - lock-protected → `Mutex` ([4.3](../04-sendable-and-safety/03-unchecked-mutex-atomics.md))
   - confined to one domain and never shared → leave it non-`Sendable`
4. **Globals and singletons** (`[#MutableGlobalVariable]`): `let`, `@MainActor`, or move the state into an actor.
5. **Callbacks and delegates**: `@MainActor` closure types, `assumeIsolated` where a framework guarantees the thread, and isolated conformances ([3.5](../03-isolation-and-actors/05-nonisolated-and-escape-hatches.md), [3.4](../03-isolation-and-actors/04-approachable-concurrency.md)).
6. **Third-party modules** that aren't annotated: use `@preconcurrency import` temporarily, and track each one.

### Stage 3: Swift 6 mode, per target
Flip `SWIFT_VERSION` / `.swiftLanguageMode(.v6)` one target at a time. Keep the escape hatches visible and countable:

```bash
grep -rnE "@unchecked Sendable|nonisolated\(unsafe\)|@preconcurrency" Sources
```

### Stage 4: approachable concurrency, with the migration tooling
The behavior-changing features (`NonisolatedNonsendingByDefault`, `InferIsolatedConformances`) have **migration modes** (SE-0486). In SwiftPM, the `swift package migrate` command applies the compiler's fix-its and updates the manifest. I ran it on a small library:

```bash
swift package migrate --to-feature NonisolatedNonsendingByDefault
```

Before:

<!-- check: lib -->
```swift
public func fetch() async -> Int { 1 }
public struct Loader { public func load() async -> [Int] { [] } }
```

After (verified output). The tool **preserved the old behavior** by adding `@concurrent` everywhere:

<!-- check: lib -->
```swift
@concurrent public func fetch() async -> Int { 1 }
public struct Loader { @concurrent public func load() async -> [Int] { [] } }
```

It also rewrote `Package.swift` to add `swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]`, and printed `Applied 2 fix-its in 1 file`.

**Then comes the real work:** go through each `@concurrent` it added and *remove* it wherever the function is cheap glue code that should simply follow its caller. Keep it only where the function does heavy or blocking work. The tool can't tell the difference. You can.

In Xcode, the same migration mode is available as the value `MIGRATE` for the `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT` and `SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES` build settings (from `Swift.xcspec`). It produces warnings with fix-its instead of changing behavior.

### Default MainActor isolation for an existing app target
Switching an existing app target to `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` changes the isolation of most unannotated code. That's usually what you want for an app target, but not for library targets. Expect three kinds of fallout:
- `Codable` and other conformances become main-actor-isolated ([3.4](../03-isolation-and-actors/04-approachable-concurrency.md)). Mark data types `nonisolated`.
- Background helpers become `@MainActor`. Mark them `nonisolated` or `@concurrent`.
- Code that was "accidentally background" now runs on main. Profile it ([7.4](../07-internals/04-performance-debugging.md)).

### What to do with each category of error (summary)
| You see | Usually the right fix |
|---|---|
| a non-`Sendable` struct crossing a boundary | add `Sendable` (or let it be inferred) |
| a mutable class shared across tasks | an actor, `@MainActor`, or a `Mutex` |
| a callback isolation mismatch | a `@MainActor` closure type, or `assumeIsolated` (if guaranteed) |
| a value used after being sent | restructure ownership: copy it, or stop using it ([4.2](../04-sendable-and-safety/02-region-isolation.md)) |
| a protocol conformance crossing actors | an isolated conformance, or `nonisolated` witnesses |
| an unannotated third-party API | `@preconcurrency import` (temporarily) |

The full diagnostic list is in [4.4](../04-sendable-and-safety/04-diagnostics-catalogue.md).

## Pitfalls
- **Big-bang migration** of the whole app at once.
- **`@MainActor` on everything** to make the errors go away, which leads to UI hitches.
- **Treating `@unchecked Sendable` as a fix.** It's a promise. Audit it with TSan.
- **Trusting `swift package migrate` blindly.** It preserves behavior. It doesn't improve the design.

## Under the hood
Migration modes compile the code *as if* the feature were off, and emit warnings with fix-its wherever enabling it would change semantics. That's why applying all the fix-its is behavior-preserving (SE-0486).

## Exercises
1. In a Swift 5 project, enable complete checking and categorize the first 20 warnings using the table above.
2. Run `swift package migrate --to-feature NonisolatedNonsendingByDefault` on a package, then remove the unnecessary `@concurrent`s. Write down your criterion.
3. Find every `static var shared` in a codebase and decide how each one should be isolated.

<details><summary>Solutions</summary>

2. A reasonable criterion: keep `@concurrent` if the function does CPU work that grows with its input (parsing, image processing, compression), or calls blocking APIs. Remove it if the function mostly awaits other async calls, or does trivial work.
3. Typically: UI-related singletons → `@MainActor`. Caches and coordinators → an `actor`. Configuration → a `let` of a `Sendable` struct. Loggers → `Sendable` structs wrapping `os.Logger`.
</details>

## Check yourself
1. Can a Swift 6 module depend on a Swift 5 module?
2. What does `swift package migrate --to-feature NonisolatedNonsendingByDefault` do to existing nonisolated async functions?
3. What's the SwiftPM spelling for per-target Swift 6 mode?

<details><summary>Answers</summary>

1. Yes. The language mode is per module.
2. It adds `@concurrent` to keep their current behavior, and enables the feature in the manifest.
3. `.swiftLanguageMode(.v6)` in `swiftSettings`, or `swiftLanguageModes: [.v6]` at the package level.
</details>

## Further reading
- *Migrating to Swift 6* guide: https://www.swift.org/migration/documentation/migrationguide/
- SE-0337 *Incremental migration to concurrency checking*
- SE-0435 *Swift Language Version Per Target*
- SE-0486 *Migration tooling for Swift features*
