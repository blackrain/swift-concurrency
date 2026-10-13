# 2.2 `async let` and task groups

## Why it matters
These are the two tools for **structured** concurrency: running work in parallel inside one async function, with a guarantee that the child tasks never outlive the scope that created them. Structured children propagate cancellation and errors automatically, and they inherit priority, task-locals and the parent's executor preference. Prefer them to `Task {}` whenever you're already in async code.

## Mental model

```
func f() async {                       ┐
    async let a = x()      ──child──┐  │  scope of f
    async let b = y()      ──child──┤  │
    await use(a, b)                 │  │
}  ◀── children are always finished ┘  ┘  (awaited, or cancelled and then awaited)
```

**The structured-concurrency guarantee:** when a scope exits, every child task it started has finished. Children are never leaked.

## Core content

### `async let`: a fixed number of children, each with its own type

<!-- check: lib -->
```swift
struct User: Sendable {}
struct Feed: Sendable {}
func fetchUser() async throws -> User { User() }
func fetchFeed() async throws -> Feed { Feed() }

func loadScreen() async throws -> (User, Feed) {
    async let user = fetchUser()       // child 1 starts now
    async let feed = fetchFeed()       // child 2 starts now
    return try await (user, feed)      // wait for both; the first error thrown propagates
}
```

Rules:
- The right-hand side runs in a **child task**, starting immediately.
- You read the value with `await` (plus `try` if the expression throws). You can read it more than once, and each read after the first returns the stored result.
- **An `async let` you never await is cancelled when its scope exits, and then awaited.** Verified: a child that sleeps 300 ms reported `cancelled` when its enclosing function returned without awaiting it. Any error it throws is discarded ([1.3](../01-async-await/03-errors-typed-throws-defer.md)).
- An `async let` can't escape its scope. You can't capture it in an escaping closure or store it.

### Task groups: a dynamic number of children, all with the same type

<!-- check: output "completion order: [\"fast\", \"mid\", \"slow\"]" -->
```swift
let order = await withTaskGroup { group in                  // ChildTaskResult inferred (SE-0442)
    for (name, ms) in [("slow", 60), ("fast", 10), ("mid", 30)] {
        group.addTask {
            try? await Task.sleep(for: .milliseconds(ms))
            return name
        }
    }
    var out: [String] = []
    for await result in group { out.append(result) }        // results arrive in COMPLETION order
    return out
}
print("completion order:", order)
```

Results arrive in **completion order**, not submission order. If you need input order, return the index together with the value:

<!-- check: lib -->
```swift
func fetch(_ id: Int) async -> String { "item\(id)" }

func fetchAllOrdered(_ ids: [Int]) async -> [String] {
    await withTaskGroup(of: (Int, String).self) { group in
        for (i, id) in ids.enumerated() {
            group.addTask { (i, await fetch(id)) }
        }
        var results = [String?](repeating: nil, count: ids.count)
        for await (i, value) in group { results[i] = value }
        return results.map { $0! }
    }
}
```

### The four group flavors

| Function | Child result | Child errors | Throws? (6.4 SDK) |
|---|---|---|---|
| `withTaskGroup(of:)` | yes | none (children are non-throwing) | no |
| `withThrowingTaskGroup(of:)` | yes | surfaced through `next()` / `for try await` | **`rethrows`**: only if the body throws |
| `withDiscardingTaskGroup` | `Void`, discarded as each child completes | none | no |
| `withThrowingDiscardingTaskGroup` | `Void` | **the first child error cancels the group and is rethrown automatically** | `throws` |

What happens to a child's error depends on the flavor. I verified each of these with a child that throws after 10 ms and a sibling that sleeps 300 ms:

1. **Throwing group, body never consumes results:** the error is **silently dropped**. The group waits for the sibling to *finish* (not cancel), and returns normally.
2. **Throwing group, body iterates with `for try await`:** the error is rethrown out of the body. The group then **cancels** the remaining children (the sibling reported `cancelled`) and awaits them before rethrowing.
3. **Throwing *discarding* group:** the first child error **automatically** cancels the siblings (the sibling reported `cancelled`) and is rethrown, without the body doing anything.

So in a regular throwing group, errors propagate only if you consume the results.

### Discarding groups: for long-running servers and fan-out
`withDiscardingTaskGroup` (SE-0381) frees each child's resources as soon as the child completes. A regular `TaskGroup` keeps completed results until you consume them, so a long-running loop that adds children forever (for example, one per incoming connection) leaks memory in a regular group, and doesn't in a discarding group.

<!-- check: lib -->
```swift
func handle(_ connection: Int) async {}

func serve(connections: AsyncStream<Int>) async {
    await withDiscardingTaskGroup { group in
        for await connection in connections {
            group.addTask { await handle(connection) }
        }
    }
}
```

### Limiting concurrency (a sliding window)
A group doesn't limit how many children run at once. That's up to the cooperative pool. To cap in-flight work (for example, at most 4 downloads at a time), add a child only when a previous one completes:

<!-- check: output "processed 20" -->
```swift
func download(_ i: Int) async -> Int { try? await Task.sleep(for: .milliseconds(5)); return i }

func downloadAll(_ ids: [Int], maxConcurrent: Int = 4) async -> [Int] {
    await withTaskGroup(of: Int.self) { group in
        var results: [Int] = []
        var iterator = ids.makeIterator()
        for _ in 0..<maxConcurrent {                           // prime the window
            guard let id = iterator.next() else { break }
            group.addTask { await download(id) }
        }
        while let done = await group.next() {                  // each completion admits one more
            results.append(done)
            if let id = iterator.next() { group.addTask { await download(id) } }
        }
        return results
    }
}

print("processed", await downloadAll(Array(1...20)).count)
```

### Other group APIs
- `group.addTaskUnlessCancelled { }` returns `false` and doesn't add the child if the group (or the parent task) is already cancelled.
- `group.cancelAll()` cancels all current children. Per the stdlib doc comment, "if you add a task to a group after canceling the group, that task is canceled immediately after being added". (On `main` there's also a `cancelAll(reason:)` with a `CancellationError.Reason`, but it **isn't in the Swift 6.4 SDK**.)
- `group.waitForAll()` waits for the remaining children and discards their results.
- `group.isEmpty`.
- `addTask(name:priority:)` sets a name and priority for a single child.

### `async let` or a task group?
| Use `async let` when… | Use a task group when… |
|---|---|
| the number of children is known when you write the code | the number of children depends on data |
| the children return different types | the children return the same type |
| you want the simplest syntax | you need completion-order results, a cap on concurrency, or early exit |

## Pitfalls & compiler errors
- **Mutating shared state from children** → `passing closure as a 'sending' parameter risks causing data races…` ([0.2](../00-foundations/02-races-deadlocks-inversion.md)). Return values from the children and combine them in the body, which runs in the parent's isolation.
- **Escaping the group:** the `group` parameter is `inout` and only valid inside the body. Don't store it or let it escape.
- **ChildTaskResult inference (SE-0442)** uses the *first* `addTask` closure. If the first child throws without returning (`group.addTask { throw X() }`), the result type is inferred as `Void`, and later `addTask { "string" }` calls fail with `cannot convert value of type 'String' to closure result type '()'` (verified). Spell it out: `withThrowingTaskGroup(of: String.self)`.
- **Expecting a throwing group to propagate child errors on its own.** It only does if you consume the results (see the table above).
- **A huge fan-out without a cap** (10,000 `addTask`s calling the network) → use the sliding window.

## Under the hood
- `async let` is cheap to create. Per `stdlib/public/Concurrency/AsyncLet.cpp`, "the compiler preallocates a large fixed space for the `async let`", and the runtime tries to place the child task context in that space. If the space isn't big enough, the runtime allocates from the parent task's stack allocator instead (the `DidAllocateFromParentTask` flag). Task-group children are created as separate tasks attached to the group.
- The group keeps a queue of completed children that haven't been consumed yet. `next()` pops from it, or suspends until a child completes. A discarding group skips that queue and releases each child immediately.
- All the `with…TaskGroup` functions take `isolation: isolated (any Actor)? = #isolation`. The body runs in the caller's isolation, which is why it can mutate local state that the children can't touch.

## Exercises
1. Write `func firstResponse(from mirrors: [String]) async throws -> String`, which races all mirrors and returns the first successful response, cancelling the rest.
2. Use a discarding group to process a stream of jobs, where one failure should stop everything.
3. Explain what happens if a child of `withTaskGroup` calls `Task.checkCancellation()` after `cancelAll()`. (It's a non-throwing group, so what does the child do?)

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
struct AllFailed: Error {}
func get(_ url: String) async throws -> String {
    try await Task.sleep(for: .milliseconds(url.count * 10))
    return url
}

func firstResponse(from mirrors: [String]) async throws -> String {
    try await withThrowingTaskGroup(of: String?.self) { group in
        for m in mirrors { group.addTask { try? await get(m) } }   // failures become nil
        for try await result in group {
            if let result {
                group.cancelAll()                                   // stop the losers
                return result
            }
        }
        throw AllFailed()
    }
}

func run(_ job: Int) async throws {}

func processAll(_ jobs: AsyncStream<Int>) async throws {
    try await withThrowingDiscardingTaskGroup { group in
        for await job in jobs {
            group.addTask { try await run(job) }   // first error cancels everything and is rethrown
        }
    }
}
```
3. `Task.checkCancellation()` throws, so it can't be called from a non-throwing child unless the child catches the error. The child has to check `Task.isCancelled` (or catch the error) and return a value. Cancellation is *cooperative*: the group can only request it.
</details>

## Check yourself
1. In what order does `for await x in group` deliver results?
2. A child of `withThrowingTaskGroup` throws, and the body never calls `next()`. What does `withThrowingTaskGroup` return or throw?
3. Why does a long-lived `TaskGroup` that adds a child per request leak memory, while a discarding group doesn't?

<details><summary>Answers</summary>

1. Completion order.
2. It returns whatever the body returns. The error is dropped, after all children finish.
3. A regular group stores each completed child's result until someone consumes it. A discarding group releases each child as soon as it completes.
</details>

## Further reading
- SE-0304 *Structured concurrency*
- SE-0317 *`async let` bindings*
- SE-0381 *DiscardingTaskGroups*
- SE-0442 *Allow TaskGroup's ChildTaskResult Type To Be Inferred*
