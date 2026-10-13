# 1.3 Errors, typed throws, async `defer`, and `Result`

## Why it matters
Async code fails in more ways than sync code: network errors, cancellation, timeouts. Swift's error model carries over to async code, but there are a few places where an error can **disappear without anyone seeing it**. This chapter maps them all, and covers three Swift 6.4 additions: async `defer`, async `Result.init(catching:)`, and the warning for unused throwing tasks.

## Mental model

```
try await f()            error propagates to the caller, exactly like sync code
async let x = f()        error surfaces at `try await x`; never awaited → silently dropped
Task { try f() }         error is stored in the task; visible only via `try await task.value`
group.addTask { … }      error surfaces from `group.next()` / `for try await` / the group's scope
```

## Core content

### `try await` works like `try`

<!-- check: lib -->
```swift
enum LoadError: Error { case notFound, corrupted }

func load(_ name: String) async throws(LoadError) -> String {
    guard name != "missing" else { throw .notFound }
    return "contents of \(name)"
}

func loadBoth() async throws(LoadError) -> (String, String) {
    let a = try await load("a")           // the thrown type is preserved: LoadError
    let b = try await load("b")
    return (a, b)
}
```

Typed throws (SE-0413) works in async functions exactly as it does in sync ones. Use it inside a module, or where the error set is truly closed. At API boundaries, `any Error` is usually more future-proof.

### Where typed throws gets erased (verified in the 6.4 SDK)
- **`Task`**: the initializers take `() async throws -> Success`, so a task created from a closure that throws `LoadError` has type `Task<…, any Error>`. I checked this: `type(of:)` printed `Task<Int, Error>` for a `throws(E)` closure.
- **Task groups**: `withThrowingTaskGroup` and `withThrowingDiscardingTaskGroup` use `any Error`.
- **`async let`** keeps the callee's error type.
- **Closures**: the compiler doesn't infer typed throws from the closure body. If you want it, annotate the closure: `{ () async throws(E) -> Int in … }`.

### Where errors silently disappear
**1. An `async let` you never await.** When the scope exits, the child task is cancelled and implicitly awaited, and its error is discarded:

<!-- check: output "no error surfaced" -->
```swift
struct Boom: Error {}
func fails() async throws -> Int { throw Boom() }

func f() async {
    async let _ = fails()          // started, never awaited
    print("returning without awaiting")
}

await f()
print("no error surfaced")
```

**2. A fire-and-forget throwing `Task`.** Swift 6.4 (SE-0520) adds a warning here:

<!-- check: lib -->
<!-- check: warning "is not used, which may accidentally ignore errors thrown inside the task" -->
```swift
struct Boom: Error {}
func risky() throws {}

func start() {
    Task { try risky() }     // ⚠️ warning in Swift 6.4
}
```

The 6.4 compiler says: `unstructured throwing task created by 'init(name:priority:operation:)' is not used, which may accidentally ignore errors thrown inside the task [#NoUseUnstructuredThrowingTask]`. To silence it, either handle the error inside the task, or write `_ = Task { … }` to make the discard explicit.

<!-- check: lib -->
```swift
struct Boom: Error {}
func risky() throws {}
func report(_ error: any Error) {}

func start() {
    Task {
        do { try risky() } catch { report(error) }    // ✅ handled inside: the task is non-throwing
    }
}
```

### Async `defer` (Swift 6.4, SE-0493)
`defer` bodies can now `await`. The awaited cleanup runs to completion before the scope exits:

<!-- check: output "async cleanup" -->
```swift
enum E: Error { case bad }
func cleanup() async { print("async cleanup") }

func work(fail: Bool) async throws(E) -> Int {
    defer { await cleanup() }     // ✅ Swift 6.4; earlier: "'async' call cannot occur in a defer body"
    if fail { throw .bad }
    return 1
}

_ = try? await work(fail: true)
```

Two details from the proposal:
- **Cancellation is still visible in `defer`.** If the task is cancelled, the cleanup code sees `Task.isCancelled == true`, and APIs that check for cancellation may skip their work. Wrap critical cleanup in `withTaskCancellationShield` ([2.3](../02-structured-concurrency/03-cancellation.md)).
- `defer` is only allowed to `await` when the enclosing context is async. In a closure, an `await` inside `defer` is enough to make the closure infer as `async`.

### `Result` with async code (Swift 6.4, SE-0530)
`Result` now has an async `init(catching:)`. It's declared in `_Concurrency` as `@_alwaysEmitIntoClient`, so it doesn't require a new OS:

<!-- check: output "failure" -->
```swift
enum E: Error { case bad }
func work() async throws(E) -> Int { throw .bad }

let untyped = await Result { try await work() }                           // Result<Int, any Error>
let typed = await Result { () async throws(E) -> Int in try await work() } // Result<Int, E>
print(untyped, typed)
```

Without an annotation, the closure infers as `throws(any Error)`. Writing `let r: Result<Int, E> = await Result { try await work() }` does **not** fix that. It fails with `invalid conversion of thrown error type 'any Error' to 'E'` (verified). You have to annotate the closure itself.

### `CancellationError`
Cancellation-aware APIs signal cancellation by throwing `CancellationError()`. `Task.sleep` throws it. So does `Task.checkCancellation()`. Treat it as a normal control-flow outcome rather than a failure to report. A common pattern:

<!-- check: lib -->
```swift
func refresh() async {
    do {
        try await Task.sleep(for: .seconds(1))
        // … fetch …
    } catch is CancellationError {
        // expected: the user navigated away; don't show an error
    } catch {
        print("real failure:", error)
    }
}
```

## Pitfalls & compiler errors
- `[#NoUseUnstructuredThrowingTask]` (6.4, warning): handle the error inside the task, or keep the task and `try await task.value`.
- `invalid conversion of thrown error type 'any Error' to 'E'`: typed throws wasn't inferred for a closure. Annotate the closure.
- `'async' call cannot occur in a defer body`: you're on a compiler before 6.4.
- Reporting `CancellationError` to users as a failure. It almost never is one.
- `URLSession` signals cancellation with `URLError(.cancelled)`, not `CancellationError`. Check for both.

## Under the hood
- When a child task throws, the error is stored in the task's result slot. Whoever awaits the child (`async let`, `group.next()` or `task.value`) re-throws it. If no one awaits it, the slot is simply released along with the task.
- An `async let` that goes out of scope without being awaited is cancelled and then **implicitly awaited**. The parent always waits for its children before returning ([2.2](../02-structured-concurrency/02-async-let-and-task-groups.md)), but the child's result is thrown away.

## Exercises
1. Write `func firstSuccessful(_ urls: [String]) async -> String?`, which tries `load(_:)` for each URL in order and returns the first success. Errors shouldn't escape.
2. Rewrite this so the error isn't lost: `func start() { Task { try await upload() } }`.
3. Use `Result` to collect the outcomes of three independent loads into an array of `Result<String, LoadError>`.

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
enum LoadError: Error { case notFound }
func load(_ name: String) async throws(LoadError) -> String {
    guard name != "missing" else { throw .notFound }
    return name
}
func upload() async throws {}

func firstSuccessful(_ urls: [String]) async -> String? {
    for url in urls {
        if let value = try? await load(url) { return value }
    }
    return nil
}

@MainActor final class Uploader {
    var lastError: (any Error)?
    func start() {
        Task {
            do { try await upload() } catch { lastError = error }   // surfaced to UI state
        }
    }
}

func loadAll() async -> [Result<String, LoadError>] {
    var results: [Result<String, LoadError>] = []
    for name in ["a", "missing", "c"] {
        results.append(await Result { () async throws(LoadError) -> String in try await load(name) })
    }
    return results
}
```
</details>

## Check yourself
1. What happens to the error of an `async let` that you never `await`?
2. What's the `Failure` type of `Task { () async throws(MyError) -> Int in … }` in Swift 6.4?
3. Does cleanup code in an async `defer` run if the task has been cancelled? Will it see the cancellation?

<details><summary>Answers</summary>

1. The child task is cancelled and implicitly awaited when the scope exits, and the error is discarded.
2. `any Error`. The `Task` initializers aren't generic over the thrown type.
3. Yes, it runs. And yes, `Task.isCancelled` is `true` inside it. Use a cancellation shield if the cleanup calls code that checks for cancellation.
</details>

## Further reading
- SE-0413 *Typed throws*
- SE-0493 *Support `async` calls in `defer` bodies*
- SE-0520 *Discardable result use in Task initializers*
- SE-0530 *Async Result Support*
