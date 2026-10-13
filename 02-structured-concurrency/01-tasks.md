# 2.1 Tasks: `Task`, `Task.detached`, priorities, names, task-locals

## Why it matters
A **task** is the unit of asynchronous work. Every async function runs as part of some task. Before going further, you need to know what a new task inherits from the code that creates it, and what it doesn't. Mixing up `Task {}` and `Task.detached {}` is one of the most common sources of isolation bugs.

## Mental model

```
Task (root)                       ← created by Task {} / Task.detached {} / the runtime (async main, .task {})
 ├─ child (async let)              ← structured: bounded by its parent's scope
 ├─ child (group.addTask)          ← structured
 │    └─ grandchild
 └─ ...
Task {} inside it                  ← unstructured: a NEW root. Inherits context, but not lifetime or cancellation
```

- **Structured** tasks (`async let`, task-group children) are part of the tree. A parent can't finish until its children finish, and cancelling a parent cancels its children.
- **Unstructured** tasks (`Task {}`, `Task.detached {}`, `Task.immediate {}`) are new roots. You hold a handle (`Task<Success, Failure>`) and are responsible for awaiting or cancelling it.

## Core content

### What a new task inherits (verified with Swift 6.4)
Here's an experiment. Inside a `@MainActor` function, running in a `.high`-priority task with a task-local value set, create one `Task` and one `Task.detached`:

<!-- check: output "local: \"req-42\"" -->
```swift
import Foundation

enum Ctx { @TaskLocal static var requestID: String = "none" }

@MainActor func probe() async {
    await Ctx.$requestID.withValue("req-42") {
        let t1 = Task(name: "plain") {
            (main: pthread_main_np() == 1, prio: Task.currentPriority, local: Ctx.requestID, name: Task.name ?? "nil")
        }
        let t2 = Task.detached(name: "detached") {
            (main: pthread_main_np() == 1, prio: Task.currentPriority, local: Ctx.requestID, name: Task.name ?? "nil")
        }
        print("Task     ", await t1.value)
        print("detached ", await t2.value)
    }
}

await Task(priority: .high) { await probe() }.value
```

Output:
```
Task      (main: true, prio: TaskPriority.high, local: "req-42", name: "plain")
detached  (main: false, prio: TaskPriority.medium, local: "none", name: "detached")
```

| | `Task { }` | `Task.detached { }` |
|---|---|---|
| Actor isolation | **inherited** (see the caveat for actors below) | none: runs on the global concurrent executor |
| Priority | inherited | default (unless you pass `priority:`) |
| Task-local values | **copied** | not inherited |
| Cancellation from the creator | **no** (it's a new root) | no |
| Must be awaited before the creator returns? | no | no |

### Caveat: inheriting an actor instance's isolation requires capturing `self`
With a **global actor** (`@MainActor`), `Task {}` always inherits the isolation. With an **actor instance**, the closure is isolated to the actor only if it captures the actor's `self` (the isolated parameter):

<!-- check: output "self captured:    Optional(" -->
```swift
actor A {
    var n = 0
    func noSelf() async -> String {
        await Task { "\(String(describing: #isolation))" }.value
    }
    func withSelf() async -> String {
        await Task { _ = self.n; return "\(String(describing: #isolation))" }.value
    }
}

let a = A()
print("no self capture: ", await a.noSelf())      // nil
print("self captured:   ", await a.withSelf())    // Optional(<YourModule>.A)
```

The rule comes from the `@_inheritActorContext` attribute on `Task.init`'s `operation` parameter: a closure inherits a parameter's isolation only if it captures that parameter (SE-0420). `#isolation` evaluates to the current isolation, as `(any Actor)?` ([3.3](../03-isolation-and-actors/03-isolation-domains.md)).

### The task handle
<!-- check: lib -->
```swift
func handles() async throws {
    let t: Task<Int, Never> = Task { 42 }
    let v = await t.value                      // wait for the value; a Never-failure task needs no try

    let u: Task<Int, any Error> = Task { throw CancellationError() }
    let r = await u.result                     // Result<Int, any Error>, never throws
    _ = (v, r)

    t.cancel()                                 // request cancellation (cooperative, see 2.3)
    print(t.isCancelled)
}
```

**Dropping the handle doesn't cancel the task.** An unstructured task runs to completion even if nothing references it. This differs from many reactive frameworks, where dropping a subscription cancels the work.

### When to use which
- **`Task {}`**: to bridge from synchronous code into async code, for example from a button action. It keeps the isolation you were in, which is almost always what UI code wants.
- **`Task.detached {}`**: rarely. Use it when you specifically want *none* of the context, for example heavy CPU work that must not inherit the main actor. In Swift 6.2+, a `@concurrent` function is usually the better tool for that ([3.4](../03-isolation-and-actors/04-approachable-concurrency.md)), because it keeps the work structured.
- **`async let` or a task group**: whenever you need concurrency *within* an async function. Prefer structured tasks; Part 2.2 explains why.

### Priorities
`TaskPriority` has `.high`, `.medium`, `.low`, `.userInitiated`, `.utility` and `.background`. `.userInitiated` is the same value as `.high`, and `.utility` is the same as `.low`. Priority is a hint to the scheduler, not a guarantee of ordering. The runtime raises (escalates) priority automatically when a higher-priority task waits on a lower-priority one ([7.3](../07-internals/03-actors-and-escalation.md)).

### Task names (Swift 6.2, SE-0469)
`Task(name:)`, `Task.detached(name:)` and the task-group `addTask(name:)` attach a human-readable name. Read it with the static `Task.name` (current task) or the instance `.name`. Names show up in debugging tools. Use them for diagnostics only, never for program logic.

### Task-local values
`@TaskLocal` declares a value bound to the task, not the thread. It's set for the duration of a scope with `withValue`, and it's inherited by child tasks and by `Task {}`, but not by `Task.detached`. This is the right tool for request IDs, tracing spans and logging context.

<!-- check: output "inner: trace-7" -->
```swift
enum Trace { @TaskLocal static var id: String? }

func log(_ msg: String) { print("\(Trace.id ?? "-"): \(msg)") }

func handle() async {
    log("start")
    async let child: Void = { log("inner: \(Trace.id ?? "-")") }()
    await child
}

await Trace.$id.withValue("trace-7") {
    await handle()
}
```

Task-locals are **read-only** inside the scope. You can't assign to them, only bind a new value for a nested scope with `withValue`.

## Pitfalls & compiler errors
- **`Task.detached` "to get off the main thread", then capturing UI state.** The closure is `sending`, so the compiler rejects capturing non-`Sendable` main-actor state. Usually the right fix is a `@concurrent` function plus `await`, not a detached task.
- **Assuming that `Task {}` inside an actor method runs on the actor.** It only does if the closure captures `self` (verified above).
- **Fire-and-forget throwing tasks.** Swift 6.4 warns about them (`[#NoUseUnstructuredThrowingTask]`, [1.3](../01-async-await/03-errors-typed-throws-defer.md)).
- **Retain cycles.** A `Task` stored in a property of `self` that captures `self` strongly creates a cycle until the task finishes. For long-running loops, capture `[weak self]`, or cancel the task in `deinit` or `onDisappear`.

## Under the hood
- `Task.init`'s operation parameter in the 6.4 SDK is declared as `@_inheritActorContext @_implicitSelfCapture operation: sending @escaping @isolated(any) () async -> Success`:
  - `@_inheritActorContext`: inherit the caller's isolation (subject to the capture rule above).
  - `@_implicitSelfCapture`: lets you use `self.` members without writing `self.` explicitly, even in classes.
  - `sending`: the closure is transferred into the new task, so it must be in a disconnected region ([4.2](../04-sendable-and-safety/02-region-isolation.md)).
  - `@isolated(any)`: the closure carries its isolation dynamically, so the runtime can start the task directly on the right executor (SE-0431).
- `Task.detached` lacks `@_inheritActorContext`, so its closure is nonisolated unless you annotate it (`Task.detached { @MainActor in … }`).
- Task-local values are stored in a linked list on the task (`stdlib/public/Concurrency/TaskLocal.cpp`). `withValue` pushes a binding and pops it when the scope ends.
  - **Structured children** *link* to the parent's list through a "parent task marker" item. The values aren't copied, because the child can't outlive the parent's bindings. The exception is bindings made *inside* a task-group body around `addTask`; those are copied.
  - **Unstructured `Task {}`** *copies* the most recent binding of each key (`swift_task_localsCopyTo`), because the new task can outlive the scope that made the binding.

## Exercises
1. Predict, then verify, what `Task.currentPriority` prints inside a `Task.detached(priority: .low) { … }` created from a `.high` task.
2. Write a `@MainActor` view model method `func refresh()` (sync) that starts an async load and stores the task, so that calling `refresh()` again cancels the previous load.
3. Add a `@TaskLocal` logger context and show that it's visible inside a task-group child.

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
@MainActor
final class FeedModel {
    private(set) var items: [String] = []
    private var loadTask: Task<Void, Never>?

    func refresh() {
        loadTask?.cancel()
        loadTask = Task {
            let fresh = await Self.fetch()
            guard !Task.isCancelled else { return }
            items = fresh                      // inherited @MainActor isolation: no await needed
        }
    }

    @concurrent static func fetch() async -> [String] {
        try? await Task.sleep(for: .milliseconds(50))
        return ["a", "b"]
    }
}

enum Log { @TaskLocal static var context = "root" }

func groupDemo() async {
    await Log.$context.withValue("import-job") {
        await withTaskGroup { group in
            group.addTask { print(Log.context) }   // prints "import-job"
        }
    }
}
```
1. It depends on timing, and that's the lesson here. I ran it three times:
   - When the `.high` parent awaits `d.value` **immediately**, it printed `TaskPriority.high` every time. Awaiting a task's value **escalates** that task to the waiter's priority, and here that happened before the detached task read its priority.
   - When the parent sleeps 50 ms before awaiting, it printed `TaskPriority.low`.

   So `Task.currentPriority` reports the *current, possibly escalated* priority, not the priority the task was created with. ([7.3](../07-internals/03-actors-and-escalation.md) covers escalation.)
</details>

## Check yourself
1. Does cancelling a task cancel the `Task {}`s created inside it?
2. Which of these does `Task.detached` inherit: isolation, priority, task-locals?
3. Inside `actor A { func f() { Task { print("hi") } } }`, is the task's closure isolated to `A`?

<details><summary>Answers</summary>

1. No. `Task {}` creates a new root task, so cancellation doesn't propagate to it.
2. None of them.
3. No. It doesn't capture `self`, so it's nonisolated. Capture `self` to make it actor-isolated.
</details>

## Further reading
- SE-0304 *Structured concurrency*
- SE-0311 *Task Local Values*
- SE-0420 *Inheritance of actor isolation*
- SE-0431 *`@isolated(any)` Function Types*
- SE-0469 *Task Naming*
