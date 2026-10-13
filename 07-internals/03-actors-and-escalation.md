# 7.3 Inside actors: state machine, job ordering, priority escalation

## Why it matters
"An actor runs one job at a time" is the contract. *How* the runtime implements it explains several behaviors that surprise people: **an actor's mailbox isn't FIFO across priorities**, hops between default actors can avoid thread switches, and priority inversions through actors get resolved automatically. This chapter reads the default-actor implementation in `stdlib/public/Concurrency/Actor.cpp`, and verifies its behavior.

## Mental model

```
ActiveActorStatus (one atomic word, or two on 64-bit with escalation support):
  ├─ state: Idle | Scheduled | Running | Zombie_ReadyForDeallocation
  ├─ max priority of the enqueued jobs
  ├─ drain lock: the identity of the thread running the actor (Darwin)
  └─ head of the incoming-job linked list (LIFO)

processing thread: takes the incoming list → reverses it → inserts into priority BUCKETS
                   → runs the highest-priority job → …
```

## Core content

### The state word
The design comment above `ActiveActorStatus` says the runtime must track, **in a single atomic**:
- "The current status of the actor - scheduled, running, idle, etc"
- "The current maximum priority of the jobs enqueued in the actor"
- "The identity of the thread currently holding the actor lock"
- "Pointer to list of jobs enqueued in actor"

The states listed in `Tracing.h` are `Idle = 0, Scheduled = 1, Running = 2, Zombie_ReadyForDeallocation = 3`. A single atomic word lets enqueue, drain and escalation race without a separate lock: every state change is a compare-and-swap.

### Job ordering: priority buckets, not FIFO
From the source (`DefaultActorImplFooter`):

> "When enqueued, jobs are atomically added to a linked list … in the LIFO order regardless of their priorities. When the processing thread sees new incoming jobs … it reverses them and inserts them into `prioritizedJobs` in the appropriate priority bucket."

Here's an experiment. Keep an actor busy for 200 ms, then call it from three `.low` tasks followed by one `.high` task:

<!-- check: output "[\"HIGH\", \"low0\", \"low1\", \"low2\"]" -->
```swift
import Foundation

actor Log {
    var order: [String] = []
    func busy() { let end = Date().addingTimeInterval(0.2); while Date() < end {} }   // hold the actor
    func record(_ s: String) { order.append(s) }
}

let log = Log()
let blocker = Task(priority: .medium) { await log.busy() }
try await Task.sleep(for: .milliseconds(30))                 // the actor is now running `busy`
var tasks: [Task<Void, Never>] = []
for i in 0..<3 {
    tasks.append(Task(priority: .low) { await log.record("low\(i)") })
    try await Task.sleep(for: .milliseconds(5))
}
tasks.append(Task(priority: .high) { await log.record("HIGH") })
for t in tasks { await t.value }
await blocker.value
print(await log.order)
```

Verified output, three runs out of three: `["HIGH", "low0", "low1", "low2"]`. The high-priority call, enqueued **last**, ran **first**, and the lows kept their relative order. **Never rely on actor calls running in submission order across different priorities.** If ordering matters, encode it explicitly: a sequence number, a single consuming task, or an `AsyncStream` that one consumer drains.

### Fast-path switching between actors
[7.1](01-runtime.md) described `swift_task_switch`. For **default** actors, the comment above the drain function explains the two outcomes of hopping from actor A to actor B on the same thread:
- "(a) We were able to hop to the new actor and so thread continues executing task. We then schedule a job for the old actor to continue if it has pending work."
- "(b) We were not able to take the fast path to the new actor, the task gets enqueued onto the new actor it is going to, and the thread now follows the actor we were trying to hop off."

So a thread alternates between "following a task" and "following an actor". It's a work-conserving scheme: a thread never sits idle while its current actor still has work.

### Priority escalation
Three mechanisms work together:
1. **Task → task.** Awaiting a task's `value` (or a child task) raises the awaited task's priority to the waiter's. Verified in [2.1](../02-structured-concurrency/01-tasks.md): a `.low` detached task awaited immediately by a `.high` task reported `.high`. In `TaskStatus.cpp`, `swift_task_escalate` returns early if the stored priority is already at least as high: escalation only goes up.
2. **Job → actor.** Enqueueing a higher-priority job raises the actor's max priority. On Darwin, the runtime then boosts **the thread currently running the actor**, using the drain-lock identity in the status word. From the source: "if a higher priority job is enqueued behind the thread executing the actor, we can escalate the thread holding the actor lock, thereby resolving the priority inversion. When a thread hops off of the actor, any priority boosts it may have gotten … is removed as well."
3. **Observable hooks (SE-0462).** `withTaskPriorityEscalationHandler` and `task.escalatePriority(to:)` ([2.4](../02-structured-concurrency/04-immediate-tasks-yield-escalation.md)).

That's why actors and `await` resolve priority inversions that semaphores can't ([0.2](../00-foundations/02-races-deadlocks-inversion.md)): the runtime always knows *who* is blocking *whom*.

### Platform note
The thread-identity tracking needs a two-word atomic. From the source: "the thread identity is only tracked on platforms which can support 128 bit atomic" operations, and with `SWIFT_CONCURRENCY_ENABLE_PRIORITY_ESCALATION`. On other configurations, the status word is smaller, and thread-level escalation isn't available.

## Pitfalls
- **Assuming FIFO order** of actor calls from tasks with different priorities (shown above).
- **Long synchronous actor methods** hold the actor. Escalation can boost the thread, but it can't preempt the method.
- **Ever-higher priorities** to "make things faster". Escalation already handles inversions. Explicit priorities should reflect user intent.

## Under the hood: reading list
- `Actor.cpp`: `ActiveActorStatus`, `DefaultActorImpl`, `defaultActorDrain`, `swift_task_switchImpl`
- `TaskStatus.cpp`: `swift_task_escalateImpl`, the status-record walk on escalation
- `Tracing.h` / `TracingSignpost.h`: the signposts behind the Instruments Swift Concurrency template ([7.4](04-performance-debugging.md))

## Exercises
1. Change the experiment so that all four calls use the same priority. What order do you expect, and why? Verify it.
2. Design a "FIFO command processor" actor API that guarantees submission order regardless of the callers' priorities.
3. Explain why escalation is implemented by boosting the *thread* holding the actor, rather than by reordering the actor's queue.

<details><summary>Solutions (outline)</summary>

1. Submission order. Verified, 3 out of 3 runs: `["low0", "low1", "low2", "low3"]`. Within one priority bucket, the runtime reverses the LIFO incoming list, which restores arrival order.
2. Expose a single `nonisolated func submit(_ cmd: Command)` that yields into an `AsyncStream` continuation (a synchronous call, so the order is fixed at the call site). One long-running task consumes the stream and applies the commands in order.
3. The job currently running can't be preempted by reordering the queue. Only boosting the thread that runs it lets it finish sooner, so the waiting high-priority job gets the actor sooner.
</details>

## Check yourself
1. Are an actor's pending jobs processed strictly FIFO?
2. What four things does `ActiveActorStatus` track?
3. How does the runtime resolve an inversion where a high-priority task waits on an actor busy with low-priority work?

<details><summary>Answers</summary>

1. No. They're grouped into priority buckets: FIFO within a priority, higher priorities first (verified).
2. The state, the max priority, the identity of the thread holding the lock, and the head of the incoming job list.
3. It raises the actor's max priority and, on Darwin, boosts the thread currently running the actor (via the drain lock).
</details>

## Further reading
- SE-0306 *Actors*
- SE-0462 *Task Priority Escalation APIs*
- `stdlib/public/Concurrency/Actor.cpp` (the long comments are the best documentation)
