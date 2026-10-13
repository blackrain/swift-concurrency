# Glossary

**Actor**: A reference type that isolates its mutable state. Only one job runs on it at a time, and it's reentrant at suspension points. → [3.1](03-isolation-and-actors/01-actors.md)

**Approachable concurrency**: The Swift 6.2 set of settings (default MainActor isolation, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, and others) that make code single-threaded by default and concurrent by opt-in. → [3.4](03-isolation-and-actors/04-approachable-concurrency.md)

**Async frame / `AsyncContext`**: The storage for an async function's activation, allocated by the task's stack-discipline allocator rather than on a thread stack. → [7.1](07-internals/01-runtime.md)

**Cancellation (cooperative)**: Setting a task's cancelled flag and running its handlers. The code has to check for it and react. → [2.3](02-structured-concurrency/03-cancellation.md)

**Cancellation shield**: A scope (6.4) inside which the current task doesn't observe cancellation. → [2.3](02-structured-concurrency/03-cancellation.md)

**Continuation**: A handle used to resume a suspended task from callback-based code. It must be resumed exactly once. → [1.2](01-async-await/02-bridging-continuations.md)

**Cooperative thread pool**: The runtime's global executor threads, about one per core (measured: 12 on 12 cores). Code is expected never to block them. → [7.1](07-internals/01-runtime.md)

**Data race**: Unsynchronized concurrent access to the same memory, where at least one access is a write. Swift 6 rules it out at compile time, outside opt-outs. → [0.2](00-foundations/02-races-deadlocks-inversion.md)

**Default actor**: An actor without a custom executor. The runtime manages its execution, and it supports the fast-path thread handoff. → [7.3](07-internals/03-actors-and-escalation.md)

**Disconnected region**: A group of non-`Sendable` values that nothing outside references. It can be transferred (`sending`). → [4.2](04-sendable-and-safety/02-region-isolation.md)

**Executor**: Something that runs jobs. *Serial* executors back actors. *Task* executors host nonisolated code for a task that has an executor preference. → [7.2](07-internals/02-executors.md)

**Global actor**: A program-wide actor (for example `@MainActor`) that can isolate many declarations. → [3.2](03-isolation-and-actors/02-global-actors.md)

**Hop**: A change of executor at an `await` (`swift_task_switch`). → [7.1](07-internals/01-runtime.md)

**Isolated conformance**: A protocol conformance usable only within a global actor's domain (`extension T: @MainActor P`). → [3.4](03-isolation-and-actors/04-approachable-concurrency.md)

**Isolation domain**: Nonisolated, an actor instance, or a global actor. Each line of code runs in exactly one of them. → [3.3](03-isolation-and-actors/03-isolation-domains.md)

**Job**: A unit of schedulable work. A task *is* a job. → [7.1](07-internals/01-runtime.md)

**Priority escalation**: The runtime raising a task's (or an actor's thread's) priority to resolve an inversion. Escalation only ever raises priority. → [7.3](07-internals/03-actors-and-escalation.md)

**Race condition**: A logic bug that depends on timing. Swift 6 doesn't prevent these (reentrancy is an example). → [0.2](00-foundations/02-races-deadlocks-inversion.md)

**Reentrancy**: Other calls running on an actor while one of its methods is suspended. → [3.1](03-isolation-and-actors/01-actors.md)

**Region-based isolation**: The compiler's flow-sensitive analysis of which non-`Sendable` values may alias, used to allow safe transfers (SE-0414). → [4.2](04-sendable-and-safety/02-region-isolation.md)

**`Sendable`**: A marker protocol for types that are safe to share across isolation domains. → [4.1](04-sendable-and-safety/01-sendable-and-sending.md)

**`sending`**: An annotation for a parameter or result that is transferred, and must be in a disconnected region. → [4.1](04-sendable-and-safety/01-sendable-and-sending.md)

**Structured concurrency**: Child tasks bounded by their parent's scope (`async let`, task groups), with cancellation and errors propagating automatically. → [2.2](02-structured-concurrency/02-async-let-and-task-groups.md)

**Suspension point**: An `await`, where the function may give up its thread. → [1.1](01-async-await/01-async-functions.md)

**Task**: The unit of asynchronous work. It has a priority, a cancellation state, task-locals, and possibly a parent. → [2.1](02-structured-concurrency/01-tasks.md)

**Task-local value**: A value bound to a task's scope (`@TaskLocal`), inherited by children and copied into `Task {}`. → [2.1](02-structured-concurrency/01-tasks.md)

**Unstructured task**: A task created with `Task {}`, `Task.immediate {}` or `Task.detached {}`. It's a new root, so its owner must manage its lifetime. → [2.1](02-structured-concurrency/01-tasks.md)
