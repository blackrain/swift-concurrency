# 0.1 Threads, queues, concurrency vs. parallelism

## Why it matters
Every feature in Swift concurrency is a structured answer to a problem from the thread-and-queue world. If you skip this chapter, actors and `Sendable` look like arbitrary rules. If you read it, they look like solutions to problems you already know.

## Mental model

```
Concurrency: several tasks are in progress during the same period.
Parallelism: several tasks execute at the same instant (needs multiple cores).

1 core, concurrent, not parallel:    A A B B A B A A B
                                     ─────────── time ──────────▶
2 cores, concurrent and parallel:    core 0: A A A A A
                                     core 1: B B B B B
```

Concurrency is about **structure**: how your program is decomposed into tasks that can make progress independently. Parallelism is about **execution**: whether the hardware runs them at the same time. Swift concurrency lets you express concurrency. The runtime decides how much parallelism to apply, based on how many cores the machine has.

## Core content

### Threads
A **thread** is an independent sequence of instructions with its own stack, scheduled by the OS kernel. Threads in a process share the heap, so two threads can both hold a reference to the same object.

Threads are relatively expensive:
- Each one reserves stack memory. On Darwin, the main thread's stack is larger than a secondary thread's default stack.
- Switching between threads (a **context switch**) goes through the kernel scheduler.
- Blocking a thread (waiting on I/O, a lock or a semaphore) keeps all of those resources tied up while no useful work happens.

### Queues (Grand Central Dispatch)
GCD replaced "create a thread" with "submit a closure to a queue":
- **Serial queue**: runs one work item at a time, in FIFO order. This gives you mutual exclusion for free.
- **Concurrent queue**: can run several work items at the same time.
- GCD keeps a pool of worker threads and maps work items onto them.

This is the classic GCD pattern: keep the state in a global and touch it only on a serial queue. Swift 6 rejects it. The compiler can't see the convention "only touched on `serial`":

<!-- check: lib -->
<!-- check: error "is not concurrency-safe because it is nonisolated global shared mutable state" -->
```swift
import Dispatch

var sum = 0                                   // ❌ in Swift 6 mode
let serial = DispatchQueue(label: "com.example.counter")

func add(_ i: Int) {
    serial.async { sum += i }                 // "only touched on `serial`" (a convention, not a guarantee)
}
```

The compiler reports `var 'sum' is not concurrency-safe because it is nonisolated global shared mutable state [#MutableGlobalVariable]`. It also suggests three fixes: make it a `let`, isolate it to `@MainActor`, or opt out with `nonisolated(unsafe)`.

> **Verified quirk:** top-level variables in `main.swift` are treated as main-actor-isolated. If you put the same code at top level in `main.swift`, Swift 6.4 only gives a *warning* ("main actor-isolated var 'sum' can not be mutated from a nonisolated context"). If you then silence it with `MainActor.assumeIsolated { sum += i }` inside the queue closure, the program traps at runtime (exit code 133, `SIGTRAP`), because the closure is not running on the main actor. Keep experiments in regular files or functions, not in `main.swift` top-level code.

Here's the same idea written so the compiler accepts it, with the state and its synchronization packaged together:

<!-- check: output "sum = 5050" -->
```swift
import Dispatch

final class Counter: @unchecked Sendable {   // safe only because every access goes through `queue`
    private let queue = DispatchQueue(label: "com.example.counter")
    private var value = 0
    func add(_ n: Int) { queue.sync { value += n } }
    var current: Int { queue.sync { value } }
}

let counter = Counter()
DispatchQueue.concurrentPerform(iterations: 100) { i in
    counter.add(i + 1)            // called in parallel from many threads
}
print("sum = \(counter.current)")
```

`@unchecked Sendable` tells the compiler "I've synchronized this myself, so don't check it." The program is correct because every access to `value` goes through `queue.sync`. Swift 6 gives you better tools for this ([actors](../03-isolation-and-actors/01-actors.md), [`Mutex`](../04-sendable-and-safety/03-unchecked-mutex-atomics.md)), but this is what the GCD era looked like.

### Concurrency vs. parallelism in Swift concurrency
Swift's async runtime runs tasks on a **cooperative thread pool** that is about as wide as the number of CPU cores. Source: `stdlib/public/Concurrency/DispatchGlobalExecutor.cpp`.
- **Apple platforms:** the runtime asks libdispatch for a global queue per priority, with a private *cooperative* flag. libdispatch limits those queues to roughly one thread per core.
- **Other platforms (Linux, etc.):** the runtime creates its own concurrent queue and sets its width to the number of logical CPUs.

You get parallelism up to the core count and no more threads than that. This only works because async code *suspends* instead of *blocking* (see [Part 7.1](../07-internals/01-runtime.md)).

## Pitfalls & compiler errors
- **"Concurrent queue" is not the same as "thread-safe".** A concurrent queue makes races *more* likely, not less.
- **Thread explosion.** With GCD, if you submit many work items that block (for example `semaphore.wait()` or synchronous I/O), GCD may spawn more threads to keep cores busy. Under load, that can mean hundreds of threads. The cooperative pool deliberately does not do this.
- **`@unchecked Sendable` is a promise you make, not a fact the compiler checks.** Forget `queue.sync` on a single access and the compiler won't tell you.

## Under the hood
- `DispatchQueue.concurrentPerform` runs the iterations in parallel and returns only after all of them have finished.
- A serial queue isn't tied to one thread. Consecutive items may run on different threads, but never at the same time. This is the same guarantee an actor gives: mutual exclusion, not thread affinity.

## Exercises
1. Write a program that increments a local `var` 1,000,000 times from `concurrentPerform` without synchronization. Run it a few times and record the results. What does the Swift 6 compiler say about it, and why is that a *warning* rather than an error? (Hint: look at how `concurrentPerform` is declared in the Dispatch module.)
2. Fix it with a serial queue, then with `NSLock`. Which one is simpler?
3. Explain in one sentence why a serial queue gives mutual exclusion but not thread affinity.

<details><summary>Solutions</summary>

1. The totals vary from run to run and are usually below 1,000,000, because `+=` is a read-modify-write that isn't atomic. Swift 6.4 says `mutation of captured var 'total' in concurrently-executing code [#SendableClosureCaptures]`. It's only a warning because Dispatch declares the method as `@preconcurrency public class func concurrentPerform(iterations:execute work: @Sendable (Int) -> Void)`, and `@preconcurrency` downgrades violations to warnings. The same capture in a `TaskGroup.addTask` closure is a hard error (see [0.2](02-races-deadlocks-inversion.md)).
2. A lock version: `lock.lock(); value += 1; lock.unlock()` (or `lock.withLock { value += 1 }`). Both versions are correct. Locks are cheaper for tiny critical sections.
3. A serial queue never runs two of its items at the same time, but any of its items may run on any pool thread.
</details>

## Check yourself
1. Can a single-core device run concurrent code? Can it run parallel code?
2. Why is blocking a thread worse than suspending a task?

<details><summary>Answers</summary>

1. Concurrent: yes, by interleaving. Parallel: no.
2. A blocked thread keeps holding its stack and its slot in the pool while it does nothing. A suspended task gives up its thread, so the thread can run other work.
</details>

## Further reading
- Apple, *Dispatch* documentation
- WWDC21, *Swift concurrency: Behind the scenes*
