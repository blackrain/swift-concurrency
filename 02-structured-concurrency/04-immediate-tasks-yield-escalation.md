# 2.4 Immediate tasks, `Task.yield`, priority escalation, and the task tree

## Why it matters
Earlier chapters covered *what* a task does. This one covers *when* it starts running and *how fast* it runs: starting synchronously with `Task.immediate`, giving up the thread with `Task.yield`, and priority escalation. These tools fix common UI glitches, such as a one-frame delay when you start a task from a button tap, and they're the hooks for advanced scheduling.

## Mental model

```
Task { }            create → ENQUEUE on its executor → runs "later" (the next time the executor gets to it)
Task.immediate { }  create → run NOW on the caller's thread → until the first REAL suspension → then like any task
```

## Core content

### `Task.immediate` (Swift 6.2, SE-0472)
An ordinary `Task {}` is **enqueued**. Even when it inherits `@MainActor`, its body runs only after the current main-actor job finishes. `Task.immediate` starts executing **synchronously on the calling executor**, and returns control to the caller only when the task actually suspends:

<!-- check: output "2 (immediate, before first suspension)" -->
```swift
@MainActor func go() async {
    print("1")
    Task.immediate {
        print("2 (immediate, before first suspension)")
        await Task.yield()
        print("4")
    }
    Task { print("5 plain Task body") }
    print("3")
    try? await Task.sleep(for: .milliseconds(100))
}

await go()
```

Verified output: `1`, `2 (immediate, before first suspension)`, `3`, then `4` and `5`. The relative order of `4` and `5` depends on scheduling. Don't depend on it.

**Isolation differs from `Task {}` (SE-0472, verified).** `Task.immediate` inherits the surrounding actor's isolation *eagerly*, whether or not the closure captures `self`. Its operation parameter is declared `@_inheritActorContext(always)`:

<!-- check: output "immediate in actor: Optional(" -->
```swift
actor A {
    func viaImmediate() async -> String {
        let t = Task.immediate { "\(String(describing: #isolation))" }   // no `self` capture
        return await t.value
    }
}
print("immediate in actor:", await A().viaImmediate())                   // Optional(<Module>.A)
```

Compare that with `Task {}` in [2.1](01-tasks.md), which is only actor-isolated if it captures `self`.

The rest of the family:
- `Task.immediateDetached`: starts immediately, but doesn't inherit isolation.
- `group.addImmediateTask { }` and `addImmediateTaskUnlessCancelled`: immediate *child* tasks. They are nonisolated by default (like `addTask`), but they *start* on the caller's executor. From the proposal: if the child never really suspends, the work effectively runs synchronously on the caller, with no parallelism at all.

**When to use it:** UI event handlers that need their first synchronous part to take effect *in the same run-loop turn* (for example, setting `isLoading = true` before the frame renders), and bridging callbacks that must observe synchronous effects in order.

### `Task.yield()`
`await Task.yield()` suspends the current task and puts it back on its executor, so other queued work can run first. Use it in long-running loops on a shared executor (the main actor, or an actor serving many callers) so that one job doesn't hog it:

<!-- check: lib -->
```swift
@MainActor
func importRecords(_ records: [Int]) async {
    for (i, record) in records.enumerated() {
        process(record)
        if i.isMultiple(of: 500) { await Task.yield() }   // let UI events run
    }
}
@MainActor func process(_ r: Int) {}
```

`Task.yield()` is a hint. If nothing else is waiting, it may resume immediately. It doesn't move work off the main actor. For that, use a `@concurrent` function ([3.4](../03-isolation-and-actors/04-approachable-concurrency.md)).

### Priority escalation (SE-0462, Swift 6.2; the APIs need OS 26+)
The runtime escalates priority automatically. A task that is awaited by a higher-priority task inherits the waiter's priority ([2.1](01-tasks.md) exercise 1 showed `.low` becoming `.high`). Swift 6.2 adds an API to **observe** escalation and to **trigger** it manually:

<!-- check: output "escalated from TaskPriority.low to TaskPriority.high" -->
```swift
let low = Task(priority: .low) {
    await withTaskPriorityEscalationHandler {
        try? await Task.sleep(for: .milliseconds(200))
        return Task.currentPriority
    } onPriorityEscalated: { old, new in
        print("escalated from \(old) to \(new)")      // forward the boost to e.g. a non-Swift work queue
    }
}
try await Task.sleep(for: .milliseconds(20))
low.escalatePriority(to: .high)
print("priority after escalation:", await low.value)   // TaskPriority.high
```

> **Proposal vs. SDK:** the text of SE-0462 specifies a *static* `Task.escalatePriority(of: task, to:)`. The Swift 6.4 SDK ships an **instance** method, `task.escalatePriority(to:)`, available on `Task` and `UnsafeCurrentTask` with `@available(anyAppleOS 26.0, *)`. This guide uses what the compiler accepts.

Escalation only ever goes **up**. In `swift_task_escalateImpl` (`TaskStatus.cpp`), if the stored priority is already at least as high as the requested one, the call returns without doing anything. You can't use it to lower a task's priority.

### The full task tree
Putting Part 2 together:

```
root Task (unstructured: Task {}, Task.immediate {}, Task.detached {}, or a system-created one)
├── async let child          ┐ structured: inherits priority, task-locals and executor preference;
├── group child              │ cancelled when the parent is; finished before the scope exits
│   └── async let grandchild ┘
└── (Task {} created here)   ← NOT a child: a separate root, with copied task-locals
```

Rules of thumb:
1. In async code, prefer structured children. Use unstructured tasks only to **enter** async code from sync code, or for work that genuinely outlives its creator.
2. If you create unstructured tasks, **own them**: store the handle and cancel it when the owner goes away.
3. Use `Task.detached` almost never. Use `Task.immediate` when ordering in the same turn matters.

### `withUnsafeCurrentTask`
<!-- check: lib -->
```swift
func inspect() {
    withUnsafeCurrentTask { task in
        guard let task else { print("not in a task"); return }
        print(task.priority, task.isCancelled)
    }
}
```

It gives you a handle to the current task, even from synchronous code. **Don't store it or let it escape the closure.** It's only valid during the call, and it's mainly useful for diagnostics.

## Pitfalls & compiler errors
- **Expecting `Task {}` to run before the next line.** It doesn't. Use `Task.immediate`, or restructure the code.
- **Using `Task.yield()` as a sleep or a synchronization primitive.** It promises nothing about ordering.
- **Expecting `addImmediateTask` children to run in parallel.** Without a real suspension, they run synchronously on the caller.
- **Calling `escalatePriority` as a static method,** as written in the proposal → `extra argument 'to' in call` in 6.4. Call it on the task instance.

## Under the hood
- `Task.immediate` creates the task and then runs its first partial function directly on the current thread, provided the current executor matches the isolation the task requires. If it doesn't match (for example, the operation is `@MainActor` but the caller is on the global pool), the task is enqueued on the right executor like a normal task. The proposal's section *Scheduling immediate tasks given matching current and requested isolation* describes this.
- Escalation updates the task's maximum priority in its atomic status, and runs any escalation handlers registered by `withTaskPriorityEscalationHandler` (the `EscalationNotification` status record). If the task is enqueued or running, it's escalated in the executor too ([7.3](../07-internals/03-actors-and-escalation.md)).

## Exercises
1. A `@MainActor` button handler does `Task { isLoading = true; await load() }`. Users report that the spinner appears one frame late. Would `Task.immediate` help? Why?
2. Write an actor method that uses `group.addImmediateTask` to run 3 children. Make one of them actually suspend, and print `#isolation` at the start of each child.
3. Explain why `Task.yield()` inside a `@concurrent` function is usually pointless.

<details><summary>Solutions</summary>

1. Yes. With `Task {}`, the body is enqueued, so `isLoading = true` runs only after the current main-actor job (the button handler) finishes, possibly after a frame has rendered. With `Task.immediate`, `isLoading = true` runs synchronously inside the handler, before `load()` first suspends. (Moving `isLoading = true` out of the task and into the handler fixes it too.)
2. Verified output: `child 0 start isolation=nil`, `child 1 start isolation=nil`, `child 2 start isolation=nil`, `body after adding children`, `child 1 resumed`. The children are nonisolated, but they start synchronously on the caller's executor: all three print *before* the group body continues. Only child 1's code after its real suspension runs later, on the global pool.
3. It runs on the cooperative pool, which already schedules many tasks across all cores. Yielding helps only when the same serial executor is shared with latency-sensitive work.
</details>

## Check yourself
1. Inside an actor method, does `Task.immediate { }` without a `self` capture run on the actor?
2. Does `await` on a call that doesn't actually suspend end the synchronous part of a `Task.immediate`?
3. Can task priority be lowered?

<details><summary>Answers</summary>

1. Yes. It inherits isolation eagerly (`@_inheritActorContext(always)`).
2. No. Only a *real* suspension returns control to the caller.
3. No. Escalation only raises it.
</details>

## Further reading
- SE-0472 *Starting tasks synchronously from caller context*
- SE-0462 *Task Priority Escalation APIs*
- SE-0469 *Task Naming*
