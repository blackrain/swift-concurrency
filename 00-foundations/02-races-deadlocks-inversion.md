# 0.2 Data races, race conditions, deadlocks, priority inversion

## Why it matters
Swift 6 promises **data-race safety** at compile time. That's a precise promise, and it's much narrower than "no concurrency bugs". This chapter separates the bug classes the compiler eliminates from the ones that are still your job.

## Mental model

| Bug | Definition | Does Swift 6 prevent it? |
|---|---|---|
| **Data race** | Two threads access the same memory at the same time, at least one access is a write, and nothing synchronizes them | **Yes**: rejected at compile time, except where you opt out (`@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency` imports, unsafe pointers) |
| **Race condition** | The result depends on the timing or interleaving of operations, even when each individual access is synchronized | **No** |
| **Deadlock** | Two or more parties each wait for something only the other can provide | **No** (async code makes some forms less likely) |
| **Priority inversion** | High-priority work waits on low-priority work that can't get scheduled | Partly: the runtime escalates priority when it knows *who* you're waiting for |

## Core content

### Data races
A data race is **undefined behavior** at the memory level. Here's a racy counter. It compiles because `@unchecked Sendable` is a manual opt-out:

<!-- check: run -->
```swift
import Dispatch

final class Box: @unchecked Sendable { var total = 0 }   // the lie

let box = Box()
DispatchQueue.concurrentPerform(iterations: 1_000_000) { _ in box.total += 1 }
print(box.total)
```

Five runs on an Apple-silicon Mac, built with `-O`, printed: `718827`, `832439`, `817006`, `756620`, `846313`. Each `+=` is load → add → store. When two threads interleave between the load and the store, one of the increments is lost.

Without the opt-out, Swift 6 catches the same pattern. Here it is with structured concurrency:

<!-- check: lib -->
<!-- check: error "passing closure as a 'sending' parameter risks causing data races" -->
```swift
func count() async -> Int {
    var total = 0
    await withTaskGroup { group in
        for _ in 0..<1000 {
            group.addTask { total += 1 }     // ❌
        }
    }
    return total
}
```

The compiler reports `passing closure as a 'sending' parameter risks causing data races between code in the current isolation context and concurrent execution of the closure [#RegionIsolation::SendingClosureRisksDataRace]`.

### Race conditions: still possible, even with actors
An actor serializes access to its state, so a data race inside one is impossible. But at every `await` inside an actor method, other calls can run (this is called **reentrancy**, covered in [3.1](../03-isolation-and-actors/01-actors.md)). So check-then-act logic that spans an `await` is a race condition:

<!-- check: output "true true -60" -->
```swift
actor Bank {
    var balance = 100
    func withdraw(_ amount: Int) async -> Bool {
        guard balance >= amount else { return false }
        try? await Task.sleep(for: .milliseconds(50))   // suspension point
        balance -= amount                               // the check above may be stale
        return true
    }
}

let bank = Bank()
async let a = bank.withdraw(80)
async let b = bank.withdraw(80)
print(await a, await b, await bank.balance)
```

This prints `true true -60`. It compiles cleanly in Swift 6 and has no data race, but the logic is wrong. The fix is to do the check and the mutation without an `await` between them. Chapter 3.1 shows the patterns for this.

### Deadlocks
The classic: thread A holds lock 1 and waits for lock 2, while thread B holds lock 2 and waits for lock 1. Async code adds a new variant: **starving the cooperative pool.** The pool has about one thread per core ([0.1](01-threads-queues-parallelism.md)). If every pool thread blocks while waiting for work that itself needs a pool thread, nothing can make progress:

<!-- check: skip -->
```swift
import Foundation

func blockingWait(_ s: DispatchSemaphore) { s.wait() }   // a sync helper hides the wait

let cores = ProcessInfo.processInfo.activeProcessorCount
await withTaskGroup { group in
    for _ in 0..<(cores * 2) {
        group.addTask {
            let sem = DispatchSemaphore(value: 0)
            Task { sem.signal() }        // needs a free pool thread to run
            blockingWait(sem)            // blocks a pool thread
        }
    }
}
print("finished")                        // never printed
```

When I ran this, it was still hung after 5 seconds and I had to kill it. (It isn't run by the guide's checker because it never terminates.) Note that **if you call `sem.wait()` directly inside the task, it does not compile**: `DispatchSemaphore.wait()` is marked unavailable from async contexts, and the compiler says *"instance method 'wait' is unavailable from asynchronous contexts; Await a Task handle instead"*. The check is shallow, though, so wrapping the call in a synchronous function gets past it. The rule to follow: **never block a thread in async code** while waiting for other async work.

### Priority inversion
Suppose a high-priority task waits on a semaphore, and a low-priority thread will signal it. The OS can't know which thread will signal, so it can't boost that thread, and medium-priority work can keep starving it. Swift concurrency improves on this whenever the relationship is *visible to the runtime*:
- If you `await` a task's `value`, the runtime knows exactly which task you're waiting on and can escalate its priority.
- If higher-priority work is enqueued on an actor, the runtime escalates the thread currently running that actor. On Darwin it records the running thread's identity in the actor's status word for exactly this purpose (source: the long comment above `ActiveActorStatus` in `stdlib/public/Concurrency/Actor.cpp`).
- With a semaphore, a condition variable, or `DispatchGroup.wait`, the runtime can't see who will signal, so it can't escalate anything. That's another reason to avoid them in async code.

Swift 6.2 also lets you observe escalation (SE-0462, `withTaskPriorityEscalationHandler`). [Chapter 7.3](../07-internals/03-actors-and-escalation.md) covers how it works.

## Pitfalls & compiler errors
- `[#RegionIsolation::SendingClosureRisksDataRace]`: a closure that captures mutable local state is passed somewhere it may run concurrently. **Fix:** don't share mutable state. Have each child return a value and combine the results.
- `[#SendableClosureCaptures]` "mutation of captured var … in concurrently-executing code": the same bug in a `@Sendable` closure. It's only a warning when the API is `@preconcurrency`, as with `DispatchQueue.concurrentPerform`.
- `is unavailable from asynchronous contexts`: you called a blocking API from async code. Use the async equivalent; don't just wrap it.

## Under the hood
- Thread Sanitizer (TSan) detects data races dynamically. Enable it in the Xcode scheme under *Diagnostics → Thread Sanitizer*, or pass `-sanitize=thread`. It finds races that actually happen while the program runs. The compiler proves the absence of races statically, except in code that has opted out. Use both: TSan is how you audit the `@unchecked` parts.
- The "unavailable from asynchronous contexts" check comes from SE-0340. The public spelling is `@available(*, noasync)`. Dispatch's interface uses the underscored form, `@_unavailableFromAsync(message: "Await a Task handle instead") public func wait()`. Either way, it's checked only at the direct call site, which is why a sync wrapper hides the call.

## Exercises
1. Fix the `count()` function above without any locks. Each child task should return `1`, and the parent should sum the results.
2. Fix `Bank.withdraw` so that the balance can never go negative, while keeping the `Task.sleep`.
3. Run the racy `Box` program with TSan enabled (`swiftc -sanitize=thread`). What does TSan report?

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
func count() async -> Int {
    await withTaskGroup(of: Int.self) { group in
        for _ in 0..<1000 { group.addTask { 1 } }
        return await group.reduce(0, +)
    }
}

actor Bank {
    var balance = 100
    func withdraw(_ amount: Int) async -> Bool {
        guard balance >= amount else { return false }
        balance -= amount                                  // reserve before suspending
        try? await Task.sleep(for: .milliseconds(50))
        return true
    }
}
```

For exercise 3, TSan (Xcode 27.1) prints `WARNING: ThreadSanitizer: Swift access race`, with stack traces for the two conflicting accesses, and a `SUMMARY: ThreadSanitizer: Swift access race … in closure #1` line.
</details>

## Check yourself
1. Does Swift 6 strict mode guarantee that your program has no race conditions?
2. Why can't the runtime fix priority inversion through a `DispatchSemaphore`?

<details><summary>Answers</summary>

1. No. It guarantees there are no *data races* outside the code you've explicitly opted out. Logical races, like the bank example, still compile.
2. A semaphore doesn't record which thread or task will signal it, so the runtime doesn't know whose priority to raise.
</details>

## Further reading
- SE-0414 *Region based isolation*
- SE-0340 *Unavailable From Async Attribute*
- SE-0462 *Task Priority Escalation APIs*
- WWDC21, *Protect mutable state with Swift actors*
