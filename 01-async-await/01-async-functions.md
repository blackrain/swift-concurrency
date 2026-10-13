# 1.1 async functions, `await`, and suspension points

## Why it matters
`async`/`await` is the foundation for everything else. The one idea to get exactly right: **`await` marks a point where the current function *may* suspend.** While it's suspended, its thread goes off to do other work, and the state of the world can change.

## Mental model

```
func load() async {
    a()                    ── runs synchronously
    let x = await b()      ── ⏸ potential suspension point
                              the thread is released; other tasks run on it
                              ... later: resume, maybe on a DIFFERENT thread
    c(x)                   ── runs after resuming
}
```

An async function is a function that can **give up its thread** in the middle of running and pick up again later. A synchronous function can't do that. It can only block the thread.

## Core content

### Declaring and calling

<!-- check: lib -->
```swift
struct Profile: Sendable { let name: String }

func fetchProfile(id: Int) async throws -> Profile {
    try await Task.sleep(for: .milliseconds(10))   // stands in for real I/O
    return Profile(name: "user\(id)")
}

func showProfile() async {
    do {
        let profile = try await fetchProfile(id: 1)   // `try` comes before `await`
        print(profile.name)
    } catch {
        print("failed:", error)
    }
}
```

The rules, all enforced by the compiler:
- An `async` function can only be called from an async context. The error is `'async' call in a function that does not support concurrency`.
- The call has to be marked with `await`. The error is `expression is 'async' but is not marked with 'await'`.
- If the call also throws, write `try await` in that order.
- One `await` covers the whole expression: `await f(g(), h())` is fine even if all three are async.

<!-- check: lib -->
<!-- check: error "'async' call in a function that does not support concurrency" -->
```swift
func work() async -> Int { 1 }

func notAsync() {
    let x = work()       // ❌ calling async code from a sync function
    print(x)
}
```

### Getting into async code: entry points
Async code can be entered in only a few places:
1. `@main` with `static func main() async`, or top-level code in `main.swift`, which may use `await` directly.
2. Creating a `Task { … }` from synchronous code ([2.1](../02-structured-concurrency/01-tasks.md)).
3. Framework hooks that are already async: SwiftUI's `.task {}` modifier, `async` test functions, and so on.

<!-- check: lib -->
<!-- check: run -->
```swift
@main
struct App {
    static func main() async {
        let n = await compute()
        print(n)
    }
    static func compute() async -> Int { 42 }
}
```

### Suspension isn't guaranteed, but you must assume it
`await` marks a *possible* suspension. If the callee completes without ever suspending (for example, an actor call made while you're already on that actor), no suspension happens. You still have to write code that is correct *if* it suspends.

### A suspension may change the thread
After a suspension, a function resumes on whatever thread its **executor** picks. Code that isn't isolated to an actor runs on the global cooperative pool, and it **can resume on a different thread**. Code isolated to `@MainActor` always resumes on the main thread. I measured both (the program is below):

- A `@concurrent` function compared `pthread_self()` before and after `await Task.sleep(for: .milliseconds(10))`. The thread changed in **64 of 200** calls on one run and **100 of 200** on another.
- A `@MainActor` function was on the main thread after resuming in **50 of 50** calls, on both runs.

<!-- check: run -->
```swift
import Foundation

@concurrent func hop() async -> Bool {          // @concurrent: always runs on the global pool (3.4)
    let before = pthread_self()
    try? await Task.sleep(for: .milliseconds(10))
    return pthread_equal(before, pthread_self()) == 0
}

@MainActor func onMain() async -> Bool {
    try? await Task.sleep(for: .milliseconds(1))
    return pthread_main_np() == 1
}

var changed = 0
for _ in 0..<200 where await hop() { changed += 1 }
print("thread changed in \(changed)/200")

var onMainCount = 0
for _ in 0..<50 where await onMain() { onMainCount += 1 }
print("MainActor resumed on main thread \(onMainCount)/50")
```

Consequences:
- **Never assume thread identity in async code.** Thread-local storage, `pthread_self()` and thread-affine C APIs won't behave as you expect after an `await`. Isolation is the abstraction you can rely on. Threads aren't.
- **Never hold a lock across an `await`.** The function might resume on a different thread. `os_unfair_lock`'s header (`<os/lock.h>`) says that unlocking from a different thread "will cause an assertion aborting the process". `Mutex.withLock` only takes a synchronous closure, which makes this mistake impossible ([4.3](../04-sendable-and-safety/03-unchecked-mutex-atomics.md)).

### Interleaving: state can change across `await`
This is the most important consequence of suspension. Anything you read before an `await` may be stale after it, unless only your own code can mutate it. [Chapter 3.1](../03-isolation-and-actors/01-actors.md) builds on this.

### Async closures, methods, initializers, getters
`async` can appear almost anywhere a function body can:

<!-- check: lib -->
```swift
struct Feed {
    init(source: String) async { /* … */ }                  // async init
    var latest: [String] { get async throws { [] } }         // async getter (no async setters)
    subscript(index: Int) -> String { get async { "\(index)" } }
    func refresh() async {}
}

func use() async throws {
    let feed = await Feed(source: "x")
    let items = try await feed.latest
    let first = await feed[0]
    let op: () async -> Void = { await feed.refresh() }      // async closure
    await op()
    print(items, first)
}
```

## Pitfalls & compiler errors
| Diagnostic | Meaning | Fix |
|---|---|---|
| `'async' call in a function that does not support concurrency` | You called async code from a sync function | Make the caller `async`, or start a `Task` if the work really is fire-and-forget |
| `expression is 'async' but is not marked with 'await'` | A missing `await` | Add `await` |
| `no 'async' operations occur within 'await' expression [#UnnecessaryEffectMarker]` (warning) | An extra `await` | Remove it |
| `instance method 'wait' is unavailable from asynchronous contexts` | Blocking API in async code | Use the async alternative |

- **Wrapping everything in `Task {}` to escape a compile error.** This breaks structure, cancellation and error propagation. Propagate `async` up the call chain instead.
- **Assuming that code between two `await`s runs atomically.** It does, but only *between* them, and only with respect to the same isolation domain.

## Under the hood
- The compiler splits an async function into **partial functions** ("continuation functions") at each potential suspension point. Local variables that are needed after a suspension live in an **async frame** that is allocated through the task's allocator, not on the thread's stack. That's why a function can resume on another thread: its state isn't on any thread's stack.
- Async frames come from a per-task allocator that "obeys a stack discipline" (`stdlib/public/Concurrency/TaskAlloc.cpp`). It carves frames out of slabs owned by the task, rather than calling `malloc` for each call. Calling an async function that doesn't suspend therefore costs a frame allocation from that slab, but no thread switch. The runtime changes executors only when isolation requires it.
- See [7.1](../07-internals/01-runtime.md) for the frame and task layout.

## Exercises
1. Write `func fetchAll(ids: [Int]) async throws -> [Profile]` that fetches the profiles *sequentially* using `fetchProfile`. (Concurrent fetching comes in [2.2](../02-structured-concurrency/02-async-let-and-task-groups.md).)
2. Explain why `let a = await x(); let b = await y()` takes the sum of both durations, not the maximum.
3. A teammate keeps a "current request ID" in thread-local storage and reads it after an `await`. What goes wrong? What should they use instead? (Hint: [2.1](../02-structured-concurrency/01-tasks.md), `@TaskLocal`.)

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
struct Profile: Sendable { let name: String }
func fetchProfile(id: Int) async throws -> Profile { Profile(name: "\(id)") }

func fetchAll(ids: [Int]) async throws -> [Profile] {
    var result: [Profile] = []
    for id in ids {
        result.append(try await fetchProfile(id: id))
    }
    return result
}
```
2. `await` doesn't start work in the background. It waits for the call to finish before moving to the next line. Concurrency needs `async let` or a task group.
3. After the `await`, the function may be running on a different thread, which has different (or stale) thread-local values. Use `@TaskLocal`, which is tied to the task, not the thread.
</details>

## Check yourself
1. Does every `await` suspend?
2. Can an `async` function running on the main actor resume on a background thread?
3. Why are async getters allowed but async setters aren't?

<details><summary>Answers</summary>

1. No. It marks a *potential* suspension.
2. No. Main-actor isolated code always resumes on the main actor, which runs on the main thread.
3. SE-0310 deliberately limited effects to read-only properties and subscripts. The goal was to keep the feature "simple, useful, and easy-to-understand", and the proposal explicitly leaves effectful setters open for future proposals. Its "Extensions considered" section explains why they're tricky (for example, interactions with `inout` and mutation).
</details>

## Further reading
- SE-0296 *Async/await*
- SE-0310 *Effectful Read-only Properties*
- SE-0323 *Asynchronous Main Semantics*
- WWDC21, *Meet async/await in Swift*
