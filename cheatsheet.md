# Swift concurrency cheatsheet (Swift 6.4)

Every entry was verified in the chapter linked next to it.

## Keywords and attributes
| Spelling | Meaning | Chapter |
|---|---|---|
| `async` / `await` | can suspend / a potential suspension point | [1.1](01-async-await/01-async-functions.md) |
| `async let x = f()` | a concurrent child task; cancelled and awaited at scope exit if never read | [2.2](02-structured-concurrency/02-async-let-and-task-groups.md) |
| `actor` | a reference type with serialized, isolated state; **reentrant** at every `await` | [3.1](03-isolation-and-actors/01-actors.md) |
| `@MainActor` / `@globalActor` | a shared isolation domain across types and functions | [3.2](03-isolation-and-actors/02-global-actors.md) |
| `nonisolated` | opts a declaration (or, since 6.1, a type/extension) out of isolation | [3.5](03-isolation-and-actors/05-nonisolated-and-escape-hatches.md) |
| `nonisolated(nonsending)` | an async function that runs on the **caller's** actor | [3.3](03-isolation-and-actors/03-isolation-domains.md) |
| `@concurrent` | an async function that always runs off the caller's actor (on the global executor) | [3.4](03-isolation-and-actors/04-approachable-concurrency.md) |
| `isolated` parameter | the function runs on that actor; `isolated (any Actor)? = #isolation` = the caller's | [3.3](03-isolation-and-actors/03-isolation-domains.md) |
| `#isolation` | the caller's current isolation, as `(any Actor)?` | [3.3](03-isolation-and-actors/03-isolation-domains.md) |
| `@isolated(any)` | a function value carrying its isolation dynamically (`f.isolation`) | [3.3](03-isolation-and-actors/03-isolation-domains.md) |
| `Sendable` / `@Sendable` | safe to *share* across domains (a marker protocol) | [4.1](04-sendable-and-safety/01-sendable-and-sending.md) |
| `sending` | safe to *transfer* (a disconnected region) | [4.1](04-sendable-and-safety/01-sendable-and-sending.md), [4.2](04-sendable-and-safety/02-region-isolation.md) |
| `~Sendable` (6.4) | explicitly non-`Sendable`; doesn't propagate to subclasses | [4.1](04-sendable-and-safety/01-sendable-and-sending.md) |
| `@unchecked Sendable` / `nonisolated(unsafe)` | trust me (unchecked) | [4.3](04-sendable-and-safety/03-unchecked-mutex-atomics.md) |
| `extension T: @MainActor P` | an isolated conformance (6.2) | [3.4](03-isolation-and-actors/04-approachable-concurrency.md) |
| `extension T: nonisolated P` | an explicitly nonisolated conformance | [3.4](03-isolation-and-actors/04-approachable-concurrency.md) |
| `@preconcurrency` (conformance) | a runtime-checked conformance (traps if misused) | [3.5](03-isolation-and-actors/05-nonisolated-and-escape-hatches.md) |
| `@preconcurrency import` | downgrades `Sendable` diagnostics from a module | [3.5](03-isolation-and-actors/05-nonisolated-and-escape-hatches.md) |
| `isolated deinit` (6.2) | deinit on the actor; macOS 15.4/iOS 18.4+, except `@MainActor` (back-deploys) | [3.1](03-isolation-and-actors/01-actors.md) |
| `defer { await … }` (6.4) | async cleanup | [1.3](01-async-await/03-errors-typed-throws-defer.md) |

## Creating work
| API | Isolation | Priority | Task-locals | Cancelled with parent | Chapter |
|---|---|---|---|---|---|
| `async let` / `group.addTask` | nonisolated (child) | inherited | inherited | **yes** | [2.2](02-structured-concurrency/02-async-let-and-task-groups.md) |
| `Task { }` | inherited (actor instance: only if `self` is captured) | inherited | copied | no | [2.1](02-structured-concurrency/01-tasks.md) |
| `Task.immediate { }` (6.2) | inherited eagerly; **starts synchronously** | inherited | copied | no | [2.4](02-structured-concurrency/04-immediate-tasks-yield-escalation.md) |
| `Task.detached { }` | none | not inherited | not inherited | no | [2.1](02-structured-concurrency/01-tasks.md) |
| SwiftUI `.task(id:)` | main actor | `.userInitiated` | — | on disappear / id change | [6.1](06-apps/01-swiftui.md) |

## Cancellation
| API | Notes | Chapter |
|---|---|---|
| `Task.isCancelled`, `try Task.checkCancellation()` | cooperative checks | [2.3](02-structured-concurrency/03-cancellation.md) |
| `withTaskCancellationHandler { } onCancel: { }` | `onCancel` runs immediately (first, if already cancelled), concurrently with the operation; don't resume or cancel while holding a lock that it takes | [2.3](02-structured-concurrency/03-cancellation.md) |
| `withTaskCancellationShield { }` (6.4, OS 27) | hides cancellation, including from children created inside | [2.3](02-structured-concurrency/03-cancellation.md) |

## Bridging
| API | Double resume | Missing resume | Chapter |
|---|---|---|---|
| `withCheckedContinuation` / `…Throwing…` (typed overload in 6.4) | trap | logs `SWIFT TASK CONTINUATION MISUSE … leaked`, then hangs | [1.2](01-async-await/02-bridging-continuations.md) |
| `withContinuation(of:)` (6.4, OS 27) | **compile error** | trap | [1.2](01-async-await/02-bridging-continuations.md) |
| `AsyncStream.makeStream(of:bufferingPolicy:)` | — | always set `onTermination` | [5.2](05-async-sequences/02-asyncstream.md) |

## Synchronization
| Tool | When | Chapter |
|---|---|---|
| `actor` | async operations, larger state | [3.1](03-isolation-and-actors/01-actors.md) |
| `Mutex<State>` (macOS 15/iOS 18) | tiny synchronous critical sections; `Sendable` for any `State` | [4.3](04-sendable-and-safety/03-unchecked-mutex-atomics.md) |
| `Atomic<Value>` | single words, lock-free; must be `let` | [4.3](04-sendable-and-safety/03-unchecked-mutex-atomics.md) |

## Build settings
| Want | Xcode | SwiftPM | Chapter |
|---|---|---|---|
| Swift 6 mode | `SWIFT_VERSION = 6` | `.swiftLanguageMode(.v6)` | [6.4](06-apps/04-migrating-to-swift-6.md) |
| MainActor by default | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | `.defaultIsolation(MainActor.self)` | [3.4](03-isolation-and-actors/04-approachable-concurrency.md) |
| async funcs follow the caller | `SWIFT_APPROACHABLE_CONCURRENCY = YES` | `.enableUpcomingFeature("NonisolatedNonsendingByDefault")` | [3.4](03-isolation-and-actors/04-approachable-concurrency.md) |
| migration help | `…_NONISOLATED_NONSENDING_BY_DEFAULT = MIGRATE` | `swift package migrate --to-feature …` | [6.4](06-apps/04-migrating-to-swift-6.md) |

## Most common diagnostics → first thing to try
| Diagnostic (abridged) | Try | Chapter |
|---|---|---|
| `… is not concurrency-safe because it is nonisolated global shared mutable state` | `let`, `@MainActor`, or an actor | [4.4 §1](04-sendable-and-safety/04-diagnostics-catalogue.md) |
| `sending 'x' risks causing data races` | stop using `x` after sending it; `sending` parameter; snapshot | [4.4 §3](04-sendable-and-safety/04-diagnostics-catalogue.md) |
| `passing closure as a 'sending' parameter risks causing data races` | return values instead of mutating captures | [4.4 §4](04-sendable-and-safety/04-diagnostics-catalogue.md) |
| `call to main actor-isolated … in a synchronous nonisolated context` | isolate the caller, or `await` | [4.4 §6](04-sendable-and-safety/04-diagnostics-catalogue.md) |
| `conformance of 'X' to protocol 'P' crosses into main actor-isolated code` | an isolated conformance | [4.4 §8](04-sendable-and-safety/04-diagnostics-catalogue.md) |
| `main actor-isolated conformance … cannot be used in @concurrent context` | a `nonisolated` type or conformance | [4.4 §9](04-sendable-and-safety/04-diagnostics-catalogue.md) |
| `non-Sendable '…'-typed result can not be returned from …` | return a `Sendable` snapshot, or `sending` | [4.4 §10](04-sendable-and-safety/04-diagnostics-catalogue.md) |

## Debugging
| Tool | Use |
|---|---|
| Instruments → *Swift Concurrency* template | task lifetimes, actor queues |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` | a 1-thread pool: blocking bugs deadlock immediately |
| LLDB `language swift task list / info / backtrace` | inspect tasks |
| `-sanitize=thread` | runtime race detection for unchecked code |
