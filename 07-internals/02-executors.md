# 7.2 Executors: `SerialExecutor`, custom actor executors, `TaskExecutor`

## Why it matters
An **executor** decides *where and when* jobs run. Default actors share the cooperative pool, and the main actor uses the main queue. Sometimes you need control: an actor whose code must run on a particular dispatch queue (because a C library requires it), or I/O-heavy work kept off the cooperative pool. Swift exposes two customization points: **custom actor executors** (SE-0392), which decide where an actor's isolated code runs, and **task executors** (SE-0417), which decide where a task's *nonisolated* code runs.

## Mental model

```
Isolated code (actor methods)  ──▶ the actor's SERIAL executor
                                    default: runtime-managed, on the cooperative pool
                                    custom:  `nonisolated var unownedExecutor` (SE-0392)

Nonisolated async code         ──▶ the task's executor PREFERENCE if set (SE-0417)
                                    otherwise the global concurrent executor (the cooperative pool)
```

## Core content

### The protocols (Swift 6.4 SDK)
<!-- check: skip -->
```swift
public protocol Executor: AnyObject, Sendable {
    func enqueue(_ job: consuming ExecutorJob)           // macOS 14 / iOS 17+ (the older UnownedJob form is deprecated)
}

public protocol SerialExecutor: Executor {
    func asUnownedSerialExecutor() -> UnownedSerialExecutor
    func isSameExclusiveExecutionContext(other: Self) -> Bool   // macOS 14 / iOS 17
    func checkIsolated()                                        // macOS 15 / iOS 18 (SE-0424): trap if not isolated
    func isIsolatingCurrentContext() -> Bool?                   // OS 26 (SE-0471): answer instead of trapping
}

public protocol TaskExecutor: Executor {                         // macOS 15 / iOS 18 (SE-0417)
    func asUnownedTaskExecutor() -> UnownedTaskExecutor
}
```

### Custom actor executor: pinning an actor to a queue (verified)
`DispatchSerialQueue` already conforms to `SerialExecutor`, so an actor can simply adopt one:

<!-- check: output "actor ran on queue: db.queue" -->
```swift
import Dispatch

actor DatabaseActor {
    let queue = DispatchSerialQueue(label: "db.queue")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    func work() -> String {
        dispatchPrecondition(condition: .onQueue(queue))     // traps if we're not on the queue
        return String(cString: __dispatch_queue_get_label(nil))
    }
}

print("actor ran on queue:", await DatabaseActor().work())
```

Use cases:
- A C or C++ library that must only be called on one thread or queue (for example, some database or audio SDKs). Pin the actor to that queue, and every isolated method is guaranteed to run there.
- **Sharing one serial executor between several actors** (return the same queue's executor from each). Those actors then exclude one another, and `assumeIsolated` and `assertIsolated` consider them the same context. The stdlib docs note: "if another actor uses the same serial executor … this check will succeed".

What you give up: the default actor's runtime-integrated fast path. `swift_task_switch` can only "assume the thread" for **default** actors ([7.1](01-runtime.md)), so hops to a custom-executor actor always enqueue.

### Task executors: where nonisolated code runs (verified)
<!-- check: output "with preference: io.pool | child: io.pool" -->
```swift
import Dispatch

final class LabeledTaskExecutor: TaskExecutor {
    let queue = DispatchQueue(label: "io.pool", attributes: .concurrent)
    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.async { unowned.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

@concurrent func whereAmI() async -> String { String(cString: __dispatch_queue_get_label(nil)) }

let executor = LabeledTaskExecutor()
let labels = await withTaskExecutorPreference(executor) {
    async let child = whereAmI()                         // structured children inherit the preference
    return (await whereAmI(), await child)
}
print("with preference:", labels.0, "| child:", labels.1)
print("without preference:", await whereAmI())
```

Verified output:

```
with preference: io.pool | child: io.pool
without preference: com.apple.root.default-qos.cooperative
```

The last line shows the default: nonisolated code runs on libdispatch's **cooperative** root queue for the task's QoS. That's the same mechanism [0.1](../00-foundations/01-threads-queues-parallelism.md) described from the source.

Ways to set a preference:
- `withTaskExecutorPreference(_:operation:)`, scoped to a block. Per SE-0417, the preference "is inherited by child tasks and actors which do not declare an explicit executor (so-called 'default actors'), and is *not* inherited by un-structured tasks";
- `Task(executorPreference:)`, `Task.detached(executorPreference:)`, and `group.addTask(executorPreference:)`;
- SwiftUI's `.task(executorPreference:)` (OS 26.4+, [6.1](../06-apps/01-swiftui.md)).

**Preference doesn't override isolation.** Actor-isolated code still runs on the actor's serial executor. The preference applies only where the code would otherwise go to the global executor. (Per SE-0417, a *default* actor's isolated code may run on the task executor's threads, but always under the actor's exclusivity.)

The use case is to **keep blocking or long I/O off the cooperative pool**. If you must call blocking APIs, give them their own thread pool through a task executor, so they never starve the cooperative pool ([0.2](../00-foundations/02-races-deadlocks-inversion.md)).

### Isolation checking with custom executors
`assumeIsolated` and `preconditionIsolated` ask the runtime "am I on this executor?" ([3.5](../03-isolation-and-actors/05-nonisolated-and-escape-hatches.md)). If the current thread isn't running a job from that executor (for example, a plain dispatch block on the same queue), the runtime asks the executor itself:
- **`isIsolatingCurrentContext() -> Bool?`** (OS 26, SE-0471) is called first. Return `true` or `false`, or `nil` for "unknown".
- **`checkIsolated()`** (macOS 15 / iOS 18, SE-0424) is the fallback. It should trap if not isolated. For the main actor (the main queue), the crash stacks in [3.5](../03-isolation-and-actors/05-nonisolated-and-escape-hatches.md) show this path ending in libdispatch's `dispatch_assert_queue`.

The environment variable `SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE` (`EnvironmentVariables.def`) selects between the behaviors: `legacy`, `swift6`, or `isIsolatingCurrentContext`. It's a migration aid for code that relied on the old non-crashing checks.

## Pitfalls
- **A custom executor that runs jobs concurrently.** A `SerialExecutor` must run one job at a time, or the actor's isolation guarantee is broken.
- **Blocking inside a custom executor's `enqueue`.** It's called synchronously by the runtime. Hand the job off, don't run long work inline.
- **Task executors with tiny pools**, used for code that waits on other tasks running on the same pool, can deadlock just like the cooperative pool.
- **Expecting custom-executor actors to have default-actor performance.** They lose the switching fast path.

## Under the hood
- `UnownedJob.runSynchronously(on:)` installs the executor as the current executor (the runtime's `ExecutorTrackingInfo`) and calls into the job. That's how isolation checks know where they are.
- At the ABI level, an executor reference is `SerialExecutorRef { HeapObject *Identity; uintptr_t Implementation; }` (`include/swift/ABI/Executor.h`). `Implementation` holds the witness table, with flags in its low bits. The runtime compares `Identity` for "same executor?" (that's what `mustSwitchToRun` does), and calls `isSameExclusiveExecutionContext` when the executor opts into complex equality. For a default actor, "the actor is the executor's identity" (SE-0417).
- A task's executor preference is stored on the task (`getPreferredTaskExecutor()` in `swift_task_switchImpl`), which is why structured children inherit it.

## Exercises
1. Wrap a hypothetical thread-confined C library (`lib_init/lib_call` must run on one thread) in an actor with a custom executor. Show that a `nonisolated` method can't call into the library.
2. Write a `TaskExecutor` backed by a fixed pool of 2 threads (`Thread` + a lock-protected job queue), and use it for blocking file reads.
3. Two actors share one serial executor. Can they deadlock by calling each other synchronously? Can they call each other *synchronously* at all?

<details><summary>Solutions (outline)</summary>

1. Use `actor LibActor { let queue = DispatchSerialQueue(label: "lib"); nonisolated var unownedExecutor … ; func call() { lib_call() } }`. A `nonisolated` method isn't on the executor, and the compiler won't let it touch isolated state. Keep the library handle as isolated state.
2. Two `Thread`s loop: take a job from a `Mutex`-protected array (blocking on a condition variable when it's empty), then `job.runSynchronously(on: asUnownedTaskExecutor())`. `enqueue` appends the `UnownedJob` and signals.
3. The compiler still treats them as different isolation domains, so calls between them require `await`. At runtime, `swift_task_switch` sees the same executor identity and doesn't need to hop. There's no deadlock: async calls never block a thread.
</details>

## Check yourself
1. Does a task executor preference change where *actor-isolated* code runs?
2. What does a custom actor executor cost you in performance?
3. Which requirement lets a custom executor *answer* an isolation check instead of trapping?

<details><summary>Answers</summary>

1. No. Isolation wins. The preference applies to nonisolated code, and (for default actors) to the threads that run them.
2. The default-actor switching fast path: hops to it always enqueue.
3. `isIsolatingCurrentContext() -> Bool?` (SE-0471).
</details>

## Further reading
- SE-0392 *Custom Actor Executors*
- SE-0417 *Task Executor Preference*
- SE-0424 *Custom isolation checking for SerialExecutor*
- SE-0471 *Improved Custom SerialExecutor isolation checking*
