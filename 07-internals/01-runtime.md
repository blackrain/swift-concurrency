# 7.1 The runtime: tasks, jobs, async frames, and the cooperative pool

## Why it matters
Expert-level performance work and debugging require a model of what actually executes: what a task *is* in memory, what `await` compiles to, why there are only as many threads as cores, and what a "hop" costs. This chapter goes through the runtime source (`swiftlang/swift`, `main`, October 2026) and checks the important claims with measurements.

## Mental model

```
AsyncTask  (a heap object; also a Job, so it can be enqueued)
 ├─ Job header: SchedulerPrivate[2], Flags (priority, kind), Id, Voucher, RunJob/ResumeTask
 ├─ ResumeContext ──▶ AsyncContext (the frame of the innermost suspended function)
 │                     ├─ Parent ──▶ the caller's AsyncContext ──▶ … (the "async call stack")
 │                     └─ ResumeParent (the continuation function to "return" into)
 └─ private: status (cancelled/escalated bits, status records), task-local list, allocator…

Executors run Jobs. Running a task's job means calling ResumeTask(ResumeContext).
```

## Core content

### 1. A task is a heap-allocated `Job`
From `include/swift/ABI/Task.h`:
- `class Job : public HeapObject` is "a schedulable job". Its header has `SchedulerPrivate[2]` (reserved for whichever executor currently owns it), `JobFlags Flags` (which encodes the priority and the job kind; the header says "Schedulers may assume the memory location of the Flags"), an `Id`, a Darwin `Voucher`, and a union of `RunJob` / `ResumeTask` function pointers.
- `class AsyncTask : public Job` adds `ResumeContext` (a pointer-authenticated `AsyncContext *`) and private storage. A comment notes it converges on "16 words of storage on all platforms" for the fixed header.
- "For async-let tasks, the refcount bits are initialized as 'immortal' because such a task is allocated with the parent's stack allocator" ([2.2](../02-structured-concurrency/02-async-let-and-task-groups.md) showed the preallocated `async let` space).

Because a task **is** a job, enqueueing a task to resume it is just enqueueing the task object itself. No separate allocation is needed per resumption.

### 2. `await` and async frames
An `async` function is compiled into a chain of **continuation functions** (partial functions) split at its potential suspension points. Each activation has an `AsyncContext`:

<!-- check: skip -->
```cpp
class alignas(MaximumAlignment) AsyncContext {
  AsyncContext *Parent;                       // the caller's context
  TaskContinuationFunction *ResumeParent;     // where to continue when we "return"
};
```

"Generally contexts are allocated using the task-local stack alloc/dealloc operations" (`Task.h`). The allocator in `TaskAlloc.cpp` "obeys a stack discipline". Frames are carved out of slabs owned by the task, so an async call is not a `malloc`. That's also why a suspended function holds no thread stack: its state lives entirely in those contexts.

Suspending means: store the next continuation function and context in the task (`ResumeTask`/`ResumeContext`), and hand the task to an executor, or to whoever will resume it (a continuation, an actor's queue, a timer). Resuming means an executor calls `ResumeTask(ResumeContext)`.

The runtime environment variable `SWIFT_DEBUG_ENABLE_TASK_SLAB_ALLOCATOR` (default `true`, in `stdlib/public/runtime/EnvironmentVariables.def` on `main`) switches the slab allocator off, "to enable use of memory debugging tools for async stack allocations". It's defined on `main`. Whether a given OS's runtime includes it depends on that runtime's version.

### 3. Hops: what `swift_task_switch` does
When isolation changes at an `await` (for example, calling an actor method), the compiler emits a call to `swift_task_switch(resumeContext, resumeFunction, newExecutor)`. (Verified: the LLVM IR for `await actor.f()` contains `swift_task_switch` calls.) Its logic, from `Actor.cpp`:
1. **`mustSwitchToRun`**: if the current serial executor already *is* the target (and the task-executor preference matches), it just tail-calls the continuation. **No hop, no suspension.**
2. Otherwise it parks the task (it stores `ResumeContext`/`ResumeTask`), and tries the **fast path**: if the current executor can give up its thread (the generic executor, or a default actor) and the new one can "assume" it (`tryAssumeThreadForSwitch` succeeds only for the generic executor or a *default actor* whose lock it can take), then **the same thread continues running the task** on the new actor. No queue and no context switch are involved.
3. Otherwise it **enqueues** the task on the new executor, and the current thread goes on to other work.

Consequences you can measure:
- Hopping between default actors and the global pool is often a lock acquisition, not a thread switch.
- **Hops to the main actor always take the enqueue path.** `MainActor` isn't a default actor. Its executor is the main dispatch queue ([3.2](../03-isolation-and-actors/02-global-actors.md)), so `tryAssumeThreadForSwitch` returns `false`. In [4.3](../04-sendable-and-safety/03-unchecked-mutex-atomics.md), a round trip main actor → actor → main actor cost about 2.7 µs per call.

### 4. The cooperative pool: one thread per core, measured
On Apple platforms, the global executor enqueues onto libdispatch's per-priority **cooperative** global queues ([0.1](../00-foundations/01-threads-queues-parallelism.md)). This program runs 64 CPU-bound tasks that never suspend, and records which threads they ran on:

<!-- check: run -->
```swift
import Foundation
import Synchronization

let threads = Mutex<Set<UInt>>([])
let active = Atomic<Int>(0), peak = Atomic<Int>(0)
func spin(_ ms: Double) { let end = Date().addingTimeInterval(ms / 1000); while Date() < end {} }

await withTaskGroup { group in
    for _ in 0..<64 {
        group.addTask {
            threads.withLock { _ = $0.insert(UInt(bitPattern: pthread_self())) }
            _ = peak.max(active.add(1, ordering: .relaxed).newValue, ordering: .relaxed)
            spin(20)                                     // CPU-bound, never suspends
            active.subtract(1, ordering: .relaxed)
        }
    }
}
print("cores:", ProcessInfo.processInfo.activeProcessorCount,
      "distinct threads:", threads.withLock { $0.count },
      "peak concurrent:", peak.load(ordering: .relaxed))
```

Measured on a 12-core Mac (`-O`):

```
cores: 12 distinct threads: 12 peak concurrent: 12
```

With the libdispatch environment variable `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`:

```
cores: 12 distinct threads: 1 peak concurrent: 1
```

That variable narrows the cooperative pool to a **single thread**. It's a debugging aid: code that only works because "something else will run on another thread" (blocking waits, semaphores) deadlocks immediately under it, instead of occasionally in production.

### 5. Why no thread explosion
GCD spawns extra threads when work items *block*, to keep cores busy. Swift's pool doesn't grow, because well-behaved async code never blocks a pool thread: it suspends, gives the thread back, and resumes later from a job. The flip side is the starvation deadlock you saw in [0.2](../00-foundations/02-races-deadlocks-inversion.md). **A blocked pool thread is a lost core**, and if all of them are blocked, the program stops.

## Pitfalls
- **Blocking in async code** (semaphores, `DispatchGroup.wait`, synchronous I/O, long CPU loops without check points) is far more damaging in the cooperative pool than it was in GCD.
- **Assuming that `await` always costs a context switch.** A same-executor `await` is a direct call. An actor-to-actor hop is often a lock handoff on the same thread.
- **Assuming hops to the main actor are cheap.** They enqueue.

## Under the hood: where to read further in the source
| Topic | File |
|---|---|
| Job / Task / AsyncContext layout | `include/swift/ABI/Task.h` |
| task allocator | `stdlib/public/Concurrency/TaskAlloc.cpp` |
| executor switching, actor runtime | `stdlib/public/Concurrency/Actor.cpp` |
| global executor on Darwin | `stdlib/public/Concurrency/DispatchGlobalExecutor.cpp` |
| status records, cancellation, escalation | `stdlib/public/Concurrency/TaskStatus.cpp` |
| runtime environment variables | `stdlib/public/runtime/EnvironmentVariables.def` |

## Exercises
1. Run the pool program with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` and the starvation program from [0.2](../00-foundations/02-races-deadlocks-inversion.md) at a smaller fan-out. How small can the fan-out get before it deadlocks?
2. Write a micro-benchmark comparing (a) calling an actor method from another actor's method, and (b) calling it from `@MainActor` code. Explain the difference using `swift_task_switch`'s fast path.
3. In your own words: why can an async function resume on a different thread without its local variables being corrupted?

<details><summary>Solutions (outline)</summary>

1. With a pool width of 1, a single blocked task is enough. Verified: the starvation program with a fan-out of **1** printed `finished` normally, but hung under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, because the blocked thread is the only one in the pool. That's exactly why the variable is useful for finding latent blocking bugs.
2. Actor → actor can use the fast path (lock handoff on the same thread, when the target is free). Main actor → actor → main actor needs an enqueue onto the main queue on the way back, so (b) is much slower per call.
3. The locals live in `AsyncContext` frames allocated by the task's allocator, not on the thread's stack. Any thread can resume the task by calling `ResumeTask(ResumeContext)`.
</details>

## Check yourself
1. Is an `AsyncTask` a `Job`?
2. When does `swift_task_switch` *not* suspend?
3. How many threads does the cooperative pool use on a 12-core Mac by default? With `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`?

<details><summary>Answers</summary>

1. Yes (`class AsyncTask : public Job`).
2. When the current executor is already the target (`mustSwitchToRun` returns `false`). The fast path also avoids enqueueing when it can take the new actor's lock on the same thread.
3. 12 (measured: 12 distinct threads, 12 peak). With the variable set: 1.
</details>

## Further reading
- WWDC21, *Swift concurrency: Behind the scenes*
- The source files listed above
