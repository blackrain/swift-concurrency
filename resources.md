# Resources

## Swift Evolution proposals referenced in this guide
The statuses below were generated from `swiftlang/swift-evolution` (`main`, October 13, 2026). "Implemented (Swift X)" is the release the proposal says it shipped in. Where the shipped SDK differs from the proposal text, the guide notes it and follows the SDK. Examples:
- SE-0462: `task.escalatePriority(to:)` (instance), not static `Task.escalatePriority(of:to:)`
- SE-0506: `withContinuousObservation`, not `withContinuousObservationTracking`
- SE-0504: the shield's parameter label is `operation:`
- SE-0520: the 6.4 `Task.init` still uses untyped `throws`

| Proposal | Title | Status |
|---|---|---|
| [SE-0296](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0296-async-await.md) | Async/await | Implemented (Swift 5.5) |
| [SE-0297](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0297-concurrency-objc.md) | Concurrency Interoperability with Objective-C | Implemented (Swift 5.5) |
| [SE-0298](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0298-asyncsequence.md) | Async/Await: Sequences | Implemented (Swift 5.5) |
| [SE-0300](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0300-continuation.md) | Continuations for interfacing async tasks with synchronous code | Implemented (Swift 5.5) |
| [SE-0302](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md) | `Sendable` and `@Sendable` closures | Implemented (Swift 5.7) |
| [SE-0304](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md) | Structured concurrency | Implemented (Swift 5.5) |
| [SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md) | Actors | Implemented (Swift 5.5) |
| [SE-0310](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0310-effectful-readonly-properties.md) | Effectful Read-only Properties | Implemented (Swift 5.5) |
| [SE-0311](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0311-task-locals.md) | Task Local Values | Implemented (Swift 5.5) |
| [SE-0313](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0313-actor-isolation-control.md) | Improved control over actor isolation | Implemented (Swift 5.5) |
| [SE-0314](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0314-async-stream.md) | `AsyncStream` and `AsyncThrowingStream` | Implemented (Swift 5.5) |
| [SE-0316](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0316-global-actors.md) | Global actors | Implemented (Swift 5.5) |
| [SE-0317](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0317-async-let.md) | `async let` bindings | Implemented (Swift 5.5) |
| [SE-0323](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0323-async-main-semantics.md) | Asynchronous Main Semantics | Implemented (Swift 5.5.2) |
| [SE-0327](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0327-actor-initializers.md) | On Actors and Initialization | Implemented (Swift 5.10) |
| [SE-0329](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0329-clock-instant-duration.md) | Clock, Instant, and Duration | Implemented (Swift 5.7) |
| [SE-0337](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md) | Incremental migration to concurrency checking | Implemented (Swift 5.6) |
| [SE-0340](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0340-swift-noasync.md) | Unavailable From Async Attribute | Implemented (Swift 5.7) |
| [SE-0371](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md) | Isolated synchronous deinit | Implemented (Swift 6.2) |
| [SE-0374](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0374-clock-sleep-for.md) | Add sleep(for:) to Clock | Implemented (Swift 5.9) |
| [SE-0381](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0381-task-group-discard-results.md) | DiscardingTaskGroups | Implemented (Swift 5.9) |
| [SE-0388](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0388-async-stream-factory.md) | Convenience Async[Throwing]Stream.makeStream methods | Implemented (Swift 5.9) |
| [SE-0392](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md) | Custom Actor Executors | Implemented (Swift 5.9) |
| [SE-0395](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0395-observability.md) | Observation | Implemented (Swift 5.9) |
| [SE-0401](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0401-remove-property-wrapper-isolation.md) | Remove Actor Isolation Inference caused by Property Wrappers | Implemented (Swift 5.9) |
| [SE-0406](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0406-async-stream-backpressure.md) | Backpressure support for AsyncStream | Returned for revision |
| [SE-0410](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0410-atomics.md) | Low-Level Atomic Operations ⚛︎ | Implemented (Swift 6.0) |
| [SE-0412](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md) | Strict concurrency for global variables | Implemented (Swift 5.10) |
| [SE-0413](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md) | Typed throws | Implemented (Swift 6.0) |
| [SE-0414](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md) | Region based Isolation | Implemented (Swift 6.0) |
| [SE-0417](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md) | Task Executor Preference | Implemented (Swift 6.0) |
| [SE-0418](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0418-inferring-sendable-for-methods.md) | Inferring `Sendable` for methods and key path literals | Implemented (Swift 6.0) |
| [SE-0420](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0420-inheritance-of-actor-isolation.md) | Inheritance of actor isolation | Implemented (Swift 6.0) |
| [SE-0421](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0421-generalize-async-sequence.md) | Generalize effect polymorphism for `AsyncSequence` and `AsyncIteratorProtocol` | Implemented (Swift 6.0) |
| [SE-0423](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0423-dynamic-actor-isolation.md) | Dynamic actor isolation enforcement from non-strict-concurrency contexts | Implemented (Swift 6.0) |
| [SE-0424](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0424-custom-isolation-checking-for-serialexecutor.md) | Custom isolation checking for SerialExecutor | Implemented (Swift 6.0) |
| [SE-0430](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md) | `sending` parameter and result values | Implemented (Swift 6.0) |
| [SE-0431](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0431-isolated-any-functions.md) | `@isolated(any)` Function Types | Implemented (Swift 6.0) |
| [SE-0433](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0433-mutex.md) | Synchronous Mutual Exclusion Lock 🔒 | Implemented (Swift 6.0) |
| [SE-0434](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0434-global-actor-isolated-types-usability.md) | Usability of global-actor-isolated types | Implemented (Swift 6.0) |
| [SE-0435](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0435-swiftpm-per-target-swift-language-version-setting.md) | Swift Language Version Per Target | Implemented (Swift 6.0) |
| [SE-0442](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0442-allow-taskgroup-childtaskresult-type-to-be-inferred.md) | Allow TaskGroup's ChildTaskResult Type To Be Inferred | Implemented (Swift 6.1) |
| [SE-0449](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0449-nonisolated-for-global-actor-cutoff.md) | Allow `nonisolated` to prevent global actor inference | Implemented (Swift 6.1) |
| [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md) | Run nonisolated async functions on the caller's actor by default | Implemented (Swift 6.2) |
| [SE-0462](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0462-task-priority-escalation-apis.md) | Task Priority Escalation APIs | Implemented (Swift 6.2) |
| [SE-0463](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0463-sendable-completion-handlers.md) | Import Objective-C completion handler parameters as `@Sendable` | Implemented (Swift 6.2) |
| [SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md) | Control default actor isolation inference | Implemented (Swift 6.2) |
| [SE-0468](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0468-async-stream-continuation-hashable-conformance.md) | `Hashable` conformance for `Async(Throwing)Stream.Continuation` | Implemented (Swift 6.2) |
| [SE-0469](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0469-task-names.md) | Task Naming | Implemented (Swift 6.2) except for the amendment |
| [SE-0470](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md) | Global-actor isolated conformances | Implemented (Swift 6.2) |
| [SE-0471](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0471-SerialExecutor-isIsolated.md) | Improved Custom SerialExecutor isolation checking for Concurrency Runtime  | Implemented (Swift 6.2) |
| [SE-0472](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0472-task-start-synchronously-on-caller-context.md) | Starting tasks synchronously from caller context | Implemented (Swift 6.2) |
| [SE-0473](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0473-clock-epochs.md) | Clock Epochs | Implemented (Swift 6.3) |
| [SE-0475](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0475-observed.md) | Transactional Observation of Values | Implemented (Swift 6.2) |
| [SE-0486](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0486-adoption-tooling-for-swift-features.md) | Migration tooling for Swift features | Implemented (Swift 6.2) |
| [SE-0493](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0493-defer-async.md) | Support `async` calls in `defer` bodies | Implemented (Swift 6.4) |
| [SE-0504](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0504-task-cancellation-shields.md) | Task Cancellation Shields | Implemented (Swift 6.4) |
| [SE-0506](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0506-advanced-observation-tracking.md) | Advanced Observation Tracking | Implemented (Swift 6.4) |
| [SE-0512](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0512-withlockifavailable-cannot-spuriously-fail.md) | Document that `Mutex.withLockIfAvailable(_:)` cannot spuriously fail | Implemented (Swift 6.0) |
| [SE-0518](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0518-tilde-sendable.md) | `~Sendable` for explicitly marking non-`Sendable` types | Implemented (Swift 6.4) |
| [SE-0520](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0520-discardableresult-task-initializers.md) | Discardable result use in Task initializers | Implemented (Swift 6.4) |
| [SE-0526](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0526-deadline.md) | withDeadline | Accepted with modifications |
| [SE-0528](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0528-noncopyable-continuation.md) | `Continuation` — Safe and Performant Async Continuations | Implemented (Swift 6.4) |
| [SE-0530](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0530-async-result-support.md) | Async Result Support | Implemented (Swift 6.4) |
| [SE-0538](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0538-disconnected.md) | Disconnected | Accepted |
| [SE-0553](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0553-task-identity.md) | Task Identity | Accepted |

**Accepted but not usable in Swift 6.4** (verified absent from the installed SDK): SE-0526 `withDeadline` (implemented on `main`), SE-0538 `Disconnected`, SE-0553 `Task.currentID`. **Returned for revision:** SE-0406 (AsyncStream backpressure).

## WWDC sessions (titles verified on developer.apple.com)
| Year | Session | Topic |
|---|---|---|
| 2021 | [10132 Meet async/await in Swift](https://developer.apple.com/videos/play/wwdc2021/10132/) | basics |
| 2021 | [10134 Explore structured concurrency in Swift](https://developer.apple.com/videos/play/wwdc2021/10134/) | tasks, groups |
| 2021 | [10133 Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/) | actors |
| 2021 | [10254 Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/) | runtime, cooperative pool |
| 2021 | [10019 Discover concurrency in SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10019/) | SwiftUI |
| 2022 | [110351 Eliminate data races using Swift Concurrency](https://developer.apple.com/videos/play/wwdc2022/110351/) | isolation, Sendable |
| 2022 | [110350 Visualize and optimize Swift concurrency](https://developer.apple.com/videos/play/wwdc2022/110350/) | Instruments |
| 2025 | [268 Embracing Swift concurrency](https://developer.apple.com/videos/play/wwdc2025/268/) | approachable concurrency |

## Documentation
- *Migrating to Swift 6*: https://www.swift.org/migration/documentation/migrationguide/
- Compiler diagnostic groups (the `[#Group]` links the compiler prints): https://docs.swift.org/compiler/documentation/diagnostics/
- Swift Testing: https://developer.apple.com/documentation/testing
- swift-async-algorithms: https://github.com/apple/swift-async-algorithms (verified against 1.1.7)
- Vision document *Improving the approachability of data-race safety*: `visions/approachable-concurrency.md` in swift-evolution

## Source code (for Part 7)
- `swiftlang/swift`: `stdlib/public/Concurrency/` (runtime + library), `include/swift/ABI/Task.h`, `Executor.h`
- `stdlib/public/runtime/EnvironmentVariables.def` (runtime debug variables)
- `include/swift/Basic/Features.def` (upcoming/experimental feature list and their language modes)

## Community
- Swift Forums, *Using Swift*: https://forums.swift.org/c/swift-users
