# 7.4 Performance and debugging

## Why it matters
Concurrency bugs and performance problems are invisible in source code. You need tools that show tasks, actors, hops and blocked threads. You also need a quantitative feel for what things cost, so you design coarse-grained boundaries from the start.

## Mental model: what things cost (measured)
I ran a micro-benchmark on an Apple-silicon Mac (12 cores, `-O`, Swift 6.4, macOS 27). It does 200,000 iterations of each operation, from a `@concurrent` function, and prints the per-iteration cost. Two runs:

| Operation | Cost per iteration |
|---|---|
| direct `await` of a nonisolated async function that doesn't suspend | 8–21 ns |
| `await actor.method()` from nonisolated code (a round trip) | ~55 ns |
| actor → another actor's method (a round trip) | ~95 ns |
| `async let x = f(); await x` | ~625 ns |
| `await Task { f() }.value` | ~800 ns |
| `await actor.method()` from **main-actor** top-level code (a round trip, [4.3](../04-sendable-and-safety/03-unchecked-mutex-atomics.md)) | ~2.7 µs |
| `Mutex.withLock` (uncontended) | ~50 ns |
| `Atomic.add` (relaxed, uncontended) | ~2 ns |

These numbers are machine-specific. Their *ratios* are the lesson:
- **Hops between default actors and the pool are cheap**, thanks to the `swift_task_switch` fast path ([7.1](01-runtime.md)). **Hops to the main actor cost about 50× more**, because they always enqueue onto the main queue.
- **Creating a task costs about 30–100× a plain call.** Don't create a task per tiny item. Batch the work into chunks.

The benchmark (so you can rerun it on your hardware):

<!-- check: run -->
```swift
actor A { var n = 0; func inc() { n += 1 } }
actor B { let a = A(); func loop(_ k: Int) async { for _ in 0..<k { await a.inc() } } }
@inline(never) func work(_ x: Int) async -> Int { x &+ 1 }

@concurrent func bench() async {
    let clock = ContinuousClock(), n = 200_000
    let direct = await clock.measure { var s = 0; for i in 0..<n { s &+= await work(i) }; precondition(s != 0) }
    let tasks = await clock.measure { for i in 0..<n { _ = await Task { await work(i) }.value } }
    let asyncLet = await clock.measure { for i in 0..<n { async let x = work(i); _ = await x } }
    let a = A()
    let toActor = await clock.measure { for _ in 0..<n { await a.inc() } }
    let b = B()
    let actorToActor = await clock.measure { await b.loop(n) }
    func per(_ d: Duration) -> String {
        let ns = Double(d.components.seconds) * 1e9 + Double(d.components.attoseconds) / 1e9
        return "\(Int(ns / Double(n))) ns"
    }
    print("direct: \(per(direct)) | Task: \(per(tasks)) | async let: \(per(asyncLet)) | →actor: \(per(toActor)) | actor→actor: \(per(actorToActor))")
}

await bench()
```

## Core content: the toolbox (all present in Xcode 27.1)

### Instruments: the *Swift Concurrency* template
`Instruments.app/Contents/Resources/templates/Swift Concurrency.tracetemplate` ships with Xcode. Its contents (inspected) include the **Swift Tasks** and **Swift Actors** instruments (`com.apple.dt.instrument.swift-concurrency-task` / `…-actor`), plus Points of Interest and CPU sampling. Use it to:
- follow each task's lifetime and state over time, and find tasks that never finish (for example, one waiting on a continuation that's never resumed, [1.2](../01-async-await/02-bridging-continuations.md));
- see how many jobs are queued on each actor. A long queue means the actor is a bottleneck: split it, or move work out of it;
- combine it with the separate **Hangs** instrument (`Hangs.instrdst` ships with Instruments) to find main-actor work that should be `@concurrent`.

The runtime emits these events as `os_signpost`s under the subsystem `com.apple.swift.concurrency` (per the `SWIFT_CONCURRENCY_TRACING_SUBSYSTEM` description in `EnvironmentVariables.def`, and `TracingSignpost.h`).

### LLDB: `language swift task`
Verified in Xcode 27.1's LLDB:
```
(lldb) language swift task list          # all discovered Swift Tasks
(lldb) language swift task info [addr]   # the current task (or one at an address)
(lldb) language swift task backtrace     # the async backtrace of a task
```
Task names (`Task(name:)`, and SwiftUI's automatic `"View.task @ file:line"`) make these lists readable ([2.1](../02-structured-concurrency/01-tasks.md), [6.1](../06-apps/01-swiftui.md)).

### `swift-inspect`
`swift-inspect` (`/usr/bin/swift-inspect`) has a `dump-concurrency` subcommand ("Print information about the target's concurrency"), for inspecting the tasks and actors of a running, possibly hung, process. It needs permission to attach to the target. Run as an unprivileged user against a normal process, it failed with `unable to get task for pid … (os/kern) failure 0x5`, so expect to need `sudo`, or a debuggable (development-signed) target.

### Thread Sanitizer
`-sanitize=thread` (Xcode: *Diagnostics → Thread Sanitizer*, or `swift test --sanitize=thread`). It catches races in `@unchecked Sendable` and `nonisolated(unsafe)` code at runtime. It reported `Swift access race` for the racy counter in [0.2](../00-foundations/02-races-deadlocks-inversion.md).

### Runtime and libdispatch environment variables
| Variable | Effect | Source / verification |
|---|---|---|
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` | narrows the cooperative pool to 1 thread, which exposes blocking bugs as immediate deadlocks | measured in [7.1](01-runtime.md) (12 → 1 threads) |
| `SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE` | `legacy`, `swift6` or `isIsolatingCurrentContext` isolation-check behavior | `EnvironmentVariables.def` |
| `SWIFT_DEBUG_CONCURRENCY_ENABLE_COOPERATIVE_QUEUES` | `false` uses plain (non-cooperative) global queues | `EnvironmentVariables.def` |
| `SWIFT_DEBUG_ENABLE_TASK_SLAB_ALLOCATOR` | `false` uses malloc for async frames (helps memory tools) | `EnvironmentVariables.def` on `main`; may not exist in older OS runtimes |

## Performance patterns
1. **Coarse actor APIs.** One hop per user action, not one per property.
2. **`@concurrent` for CPU-heavy work, never the main actor.** Check with Instruments' Hangs instrument.
3. **Batch fan-out.** For 100,000 small items, use about `activeProcessorCount` children, each processing a chunk.
4. **Avoid a `Task {}` per event in hot paths.** Feed an `AsyncStream` consumed by one task instead.
5. **`Mutex` / `Atomic` for hot, tiny shared state** ([4.3](../04-sendable-and-safety/03-unchecked-mutex-atomics.md)).
6. **Check point long CPU loops** with `try Task.checkCancellation()` (and `await Task.yield()` on shared executors).

## Pitfalls
- **Trusting micro-benchmarks across machines.** Re-measure on your target devices, and compare ratios rather than absolute numbers.
- **Profiling Debug builds.** I measured the same benchmark at `-Onone`: a direct async call took 197 ns instead of 8 ns, and the actor round trip 163 ns instead of 54 ns. Profile Release builds.
- **Leaving `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` on** outside of debugging sessions. It serializes all concurrent work.

## Debugging recipes
| Symptom | Likely cause | Tool |
|---|---|---|
| the app freezes, CPU at 0% | a starved cooperative pool (blocking waits), or a continuation that's never resumed | `swift-inspect dump-concurrency`, LLDB `task list`, rerun with `POOL_STRICT=1` |
| UI stutters during loading | heavy work on the main actor (often "accidental" after `NonisolatedNonsendingByDefault`) | Instruments: Hangs + Swift Concurrency |
| an intermittently wrong result | a reentrancy race in an actor ([3.1](../03-isolation-and-actors/01-actors.md)) | review every `await` inside actor methods |
| a crash in `assumeIsolated` / `@preconcurrency` | a callback arrived on an unexpected thread | the crash stack shows `_checkExpectedExecutor` / `dispatch_assert_queue` ([3.5](../03-isolation-and-actors/05-nonisolated-and-escape-hatches.md)) |
| `SWIFT TASK CONTINUATION MISUSE` in the logs | a continuation leaked or was resumed twice | the message names the function ([1.2](../01-async-await/02-bridging-continuations.md)) |

## Under the hood
The Swift Concurrency instruments consume `os_signpost` events that the runtime emits under the subsystem `com.apple.swift.concurrency` (`stdlib/public/Concurrency/TracingSignpost.h`). `SWIFT_CONCURRENCY_TRACING_SUBSYSTEM` (on `main`) overrides the subsystem, which is useful for testing, "since the default subsystem has signposts disabled by system logging preferences" (`EnvironmentVariables.def`).

## Exercises
1. Run the benchmark on your machine, and compute the main-actor-hop to actor-hop ratio.
2. Write a version of a 100,000-item transform that uses one task per item, and one that uses 12 chunked tasks. Measure both.
3. Reproduce a continuation leak, and find it with the Swift Concurrency instrument.

<details><summary>Solutions (outline)</summary>

1. On the reference machine, about 2.7 µs ÷ 55 ns ≈ 50×.
2. With ~800 ns of task overhead per item, the one-task-per-item version spends about 80 ms on overhead alone. The chunked version pays it 12 times.
3. The task shows up as permanently waiting on a continuation, and the log contains `SWIFT TASK CONTINUATION MISUSE: … leaked its continuation`.
</details>

## Check yourself
1. Why is an actor-to-actor hop much cheaper than a hop to the main actor?
2. Which environment variable turns latent pool-blocking bugs into immediate deadlocks?
3. What LLDB command lists all Swift tasks?

<details><summary>Answers</summary>

1. Default actors support the "assume the thread" fast path in `swift_task_switch`. The main actor's executor is the main dispatch queue, so hops to it always enqueue.
2. `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`.
3. `language swift task list`.
</details>

## Further reading
- WWDC22, *Visualize and optimize Swift concurrency*
- WWDC21, *Swift concurrency: Behind the scenes*
