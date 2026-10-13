# Mastering Swift Concurrency

A guide to Swift concurrency that starts at the basics and ends at the runtime internals. It targets **Swift 6.2+** (verified against **Swift 6.4 / Xcode 27.1**) and is written with iOS and macOS app developers in mind.

## How this guide was verified

- **Every `swift` code block is compiled.** Each block is compiled in Swift 6 language mode with `swiftc` 6.4 for `arm64-apple-macos27.0`, including the SIL passes where region-based isolation errors are reported. Some blocks exist to show an error. Each of those carries an HTML comment (`<!-- check: error "…" -->`) with the text of the expected diagnostic, and the build fails if the compiler doesn't produce it. Blocks that claim a runtime output were run, and their output was compared with what the text says. The only blocks that aren't compiled are API signatures and pseudo-code, and those are marked `<!-- check: skip -->`.
- **API names and proposal status** were checked against the `swiftlang/swift-evolution` and `swiftlang/swift` repositories (main branch, October 2026) and against the `.swiftinterface` files in the installed SDK.
- **The diagnostics quoted in the text** come from the compiler output, not from memory. The `[#GroupName]` suffixes are the compiler's diagnostic group names. The compiler documents each group, and you can look them up.
- Some things are accepted but not yet usable in Swift 6.4: `Disconnected` (SE-0538), `Task.currentID` (SE-0553) and `withDeadline` (SE-0526). The guide labels them **"accepted, not shipped in 6.4"**, and none of the examples depend on them.

To re-verify the guide on a newer toolchain, run `python3 tools/check-snippets.py .`. It compiles every block, checks the expected diagnostics, and runs the blocks that claim an output. The external-package snippets in 5.3 and the Swift Testing snippets in 6.5 were verified in separate SwiftPM packages.

## Roadmap

| Part | Level | You will be able to… |
|---|---|---|
| [0. Foundations](00-foundations/01-threads-queues-parallelism.md) | Beginner | Explain threads, data races and deadlocks, and say why GCD-era code was hard to get right |
| [1. async/await](01-async-await/01-async-functions.md) | Beginner → Intermediate | Write and bridge async code, and reason about suspension points |
| [2. Structured concurrency](02-structured-concurrency/01-tasks.md) | Intermediate | Use tasks, task groups and cancellation the right way |
| [3. Isolation & actors](03-isolation-and-actors/01-actors.md) | Intermediate → Advanced | Know which isolation domain every line of code runs in |
| [4. Sendable & data-race safety](04-sendable-and-safety/01-sendable-and-sending.md) | Advanced | Read and fix any Swift 6 data-race diagnostic |
| [5. Async sequences](05-async-sequences/01-asyncsequence.md) | Intermediate → Advanced | Model streams of values, with and without Combine |
| [6. Concurrency in apps](06-apps/01-swiftui.md) | Advanced | Architect, migrate and test a SwiftUI app under Swift 6 |
| [7. Internals](07-internals/01-runtime.md) | Expert | Understand the runtime, executors and performance at the level of the implementation |
| [Capstone](capstone.md) | Expert | Build and review a complete app |

## Table of contents

**Part 0: Foundations**
- [0.1 Threads, queues, concurrency vs. parallelism](00-foundations/01-threads-queues-parallelism.md)
- [0.2 Data races, race conditions, deadlocks, priority inversion](00-foundations/02-races-deadlocks-inversion.md)
- [0.3 The callback world and why it was replaced](00-foundations/03-callbacks-and-gcd-problems.md)

**Part 1: async/await**
- [1.1 async functions, `await`, and suspension points](01-async-await/01-async-functions.md)
- [1.2 Bridging callback APIs with continuations](01-async-await/02-bridging-continuations.md)
- [1.3 Errors, typed throws, async `defer`, and `Result`](01-async-await/03-errors-typed-throws-defer.md)
- [1.4 `async` in the type system, and a first look at `async let`](01-async-await/04-async-in-the-type-system.md)

**Part 2: Structured concurrency**
- [2.1 Tasks: `Task`, `Task.detached`, priorities, names, task-locals](02-structured-concurrency/01-tasks.md)
- [2.2 `async let` and task groups](02-structured-concurrency/02-async-let-and-task-groups.md)
- [2.3 Cancellation](02-structured-concurrency/03-cancellation.md)
- [2.4 Immediate tasks, `Task.yield`, priority escalation, and the task tree](02-structured-concurrency/04-immediate-tasks-yield-escalation.md)

**Part 3: Isolation & actors**
- [3.1 Actors: isolation and reentrancy](03-isolation-and-actors/01-actors.md)
- [3.2 Global actors and `@MainActor`](03-isolation-and-actors/02-global-actors.md)
- [3.3 Isolation domains, `isolated` parameters, `#isolation`, `@isolated(any)`](03-isolation-and-actors/03-isolation-domains.md)
- [3.4 Swift 6.2 "Approachable Concurrency": default isolation, `nonisolated(nonsending)`, `@concurrent`, isolated conformances](03-isolation-and-actors/04-approachable-concurrency.md)
- [3.5 `nonisolated`, `nonisolated(unsafe)`, `assumeIsolated`, `@preconcurrency`: the escape hatches](03-isolation-and-actors/05-nonisolated-and-escape-hatches.md)

**Part 4: Sendable & data-race safety**
- [4.1 `Sendable`, `@Sendable`, `sending`, and `~Sendable`](04-sendable-and-safety/01-sendable-and-sending.md)
- [4.2 Region-based isolation: how the compiler reasons about non-`Sendable` values](04-sendable-and-safety/02-region-isolation.md)
- [4.3 `Mutex`, `Atomic`, locks, and `@unchecked Sendable`](04-sendable-and-safety/03-unchecked-mutex-atomics.md)
- [4.4 The Swift 6 diagnostics catalogue](04-sendable-and-safety/04-diagnostics-catalogue.md)

**Part 5: Async sequences**
- [5.1 `AsyncSequence`: values over time](05-async-sequences/01-asyncsequence.md)
- [5.2 `AsyncStream` and `AsyncThrowingStream`](05-async-sequences/02-asyncstream.md)
- [5.3 swift-async-algorithms, and replacing Combine](05-async-sequences/03-async-algorithms.md)
- [5.4 Observation and concurrency: `@Observable`, `Observations`, and observation tracking](05-async-sequences/04-observation.md)

**Part 6: Concurrency in apps**
- [6.1 SwiftUI and concurrency](06-apps/01-swiftui.md)
- [6.2 App architecture under Swift 6](06-apps/02-architecture.md)
- [6.3 Networking and persistence](06-apps/03-networking-persistence.md)
- [6.4 Migrating an app to Swift 6](06-apps/04-migrating-to-swift-6.md)
- [6.5 Testing concurrent code](06-apps/05-testing.md)

**Part 7: Internals**
- [7.1 The runtime: tasks, jobs, async frames, and the cooperative pool](07-internals/01-runtime.md)
- [7.2 Executors: `SerialExecutor`, custom actor executors, `TaskExecutor`](07-internals/02-executors.md)
- [7.3 Inside actors: state machine, job ordering, priority escalation](07-internals/03-actors-and-escalation.md)
- [7.4 Performance and debugging](07-internals/04-performance-debugging.md)
- [7.5 Clocks, time, timeouts](07-internals/05-clocks-and-time.md)
- [7.6 Patterns and anti-patterns: an expert's review checklist](07-internals/06-patterns-and-antipatterns.md)

**[Capstone: an offline-first feed app](capstone.md)** · [Cheatsheet](cheatsheet.md) · [Glossary](glossary.md) · [Resources](resources.md)

## How every chapter is structured

1. **Why it matters**: the problem the feature solves.
2. **Mental model**: a picture to keep in your head.
3. **Core content**: the material itself, with compiled examples.
4. **Pitfalls & compiler errors**: real diagnostics and how to fix them.
5. **Under the hood**: how the feature actually works.
6. **Exercises**: solutions are inside the collapsed `<details>` blocks.
7. **Check yourself**: a short quiz.
8. **Further reading**: Swift Evolution proposals and documentation.

## Prerequisites

- You're comfortable with Swift itself: closures, protocols, generics, value vs. reference types, and `throws`.
- You have Xcode 26 or later (Swift 6.2+). The examples were verified with Xcode 27.1 (Swift 6.4).
- Run the snippets in a macOS command-line target or a Swift package, with the language mode set to **Swift 6**.

## Version notes you must know up front

Several behaviors depend on build settings, not only on the Swift version. When this guide says *"default Swift 6 mode"*, it means `-swift-version 6` with nothing else enabled. These are the settings that change behavior. They were verified in Xcode 27.1's `Swift.xcspec` and in the compiler's `Features.def`:

| Xcode build setting | Compiler flag | Effect |
|---|---|---|
| `SWIFT_VERSION = 6` | `-swift-version 6` | Complete strict concurrency checking. Data-race diagnostics are errors. |
| `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | `-default-isolation MainActor` | Unannotated code in the module is inferred to be `@MainActor` (SE-0466). |
| `SWIFT_APPROACHABLE_CONCURRENCY = YES` | `-enable-upcoming-feature …` (five features) | Turns on `DisableOutwardActorInference`, `GlobalActorIsolatedTypesUsability`, `InferIsolatedConformances`, `InferSendableFromCaptures` and `NonisolatedNonsendingByDefault` |

The two most important upcoming features are `NonisolatedNonsendingByDefault` (SE-0461) and `InferIsolatedConformances` (SE-0470). In Swift 6.4 both are still opt-in. They are scheduled for a *future* language mode and are **not** enabled by `-swift-version 6` alone.

**What a new Xcode 27.1 project actually contains** (from Xcode's own project templates):
- `SWIFT_VERSION = 5.0` (note: the Swift 5 language mode, not 6)
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- for app targets, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`

The two future-mode features take their default value from `SWIFT_APPROACHABLE_CONCURRENCY`, and they apply whether the target is in Swift 5 or Swift 6 mode. A fresh app project is therefore **MainActor-by-default** and **nonisolated(nonsending)-by-default**, but it isn't in Swift 6 mode until you change `SWIFT_VERSION`. A Swift package gets none of this unless you set it in `Package.swift`. [Chapter 3.4](03-isolation-and-actors/04-approachable-concurrency.md) explains why this matters.
