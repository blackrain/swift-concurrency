# 0.3 The callback world and why it was replaced

## Why it matters
Most Apple frameworks and many codebases still contain completion-handler APIs. You'll be bridging them for years (see [1.2](../01-async-await/02-bridging-continuations.md)), and you'll only bridge them well once you can name exactly what goes wrong with them.

## Mental model

```
Callback style:  call ──▶ returns immediately
                          ... later, on some thread ...
                          completion(result)  ← maybe once, maybe never, maybe twice

async style:     let result = try await call()   ← resumes exactly once, with a value or an error
```

## Core content

Here's a realistic three-step operation written with completion handlers:

<!-- check: lib -->
```swift
import Foundation

struct User: Sendable { let id: Int }
struct Avatar: Sendable { let bytes: Data }
enum AppError: Error { case notFound }

func fetchUser(id: Int, completion: @escaping @Sendable (Result<User, Error>) -> Void) {
    DispatchQueue.global().async { completion(.success(User(id: id))) }
}
func fetchAvatarURL(for user: User, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
    DispatchQueue.global().async { completion(.success(URL(string: "https://example.com/\(user.id)")!)) }
}
func download(_ url: URL, completion: @escaping @Sendable (Result<Avatar, Error>) -> Void) {
    DispatchQueue.global().async { completion(.success(Avatar(bytes: Data()))) }
}

func loadAvatar(id: Int, completion: @escaping @Sendable (Result<Avatar, Error>) -> Void) {
    fetchUser(id: id) { result in
        switch result {
        case .failure(let e): completion(.failure(e))
        case .success(let user):
            fetchAvatarURL(for: user) { result in
                switch result {
                case .failure(let e): completion(.failure(e))
                case .success(let url):
                    download(url) { result in
                        completion(result)     // forget this line and the caller waits forever
                    }
                }
            }
        }
    }
}
```

And here's the same operation with async/await:

<!-- check: lib -->
```swift
import Foundation

struct User: Sendable { let id: Int }
struct Avatar: Sendable { let bytes: Data }

func fetchUser(id: Int) async throws -> User { User(id: id) }
func fetchAvatarURL(for user: User) async throws -> URL { URL(string: "https://example.com/\(user.id)")! }
func download(_ url: URL) async throws -> Avatar { Avatar(bytes: Data()) }

func loadAvatar(id: Int) async throws -> Avatar {
    let user = try await fetchUser(id: id)
    let url = try await fetchAvatarURL(for: user)
    return try await download(url)
}
```

### The problems, named
1. **Exactly-once is not enforced.** The compiler can't tell whether a completion handler gets called zero, one or two times. An `async` function returns or throws exactly once on every path, and the compiler checks that like it checks any other function.
2. **Error propagation is manual.** Every level needs its own `switch`/`case .failure` boilerplate. With async/await, `try` propagates errors automatically.
3. **Which thread runs the callback?** It depends on the API, and you find out from the documentation (if it says) or by testing. Developers wrapped callbacks in `DispatchQueue.main.async` "just in case". With async/await, isolation is part of the type system ([Part 3](../03-isolation-and-actors/)).
4. **Cancellation has no standard shape.** Each API invents its own token, flag or `cancel()` method. Swift concurrency has a single cooperative cancellation model that propagates through the task tree ([2.3](../02-structured-concurrency/03-cancellation.md)).
5. **Lifetimes are unstructured.** Nothing ties a callback chain to the scope that started it, so `[weak self]` is everywhere. Structured concurrency ties child work to a scope ([Part 2](../02-structured-concurrency/)).
6. **Control flow can't be expressed naturally.** Loops, early returns and `defer` don't work across callbacks. Retrying a request three times needs recursion. In async code it's a `for` loop.

## Pitfalls & compiler errors
- A completion handler that isn't `@Sendable` but is called from another queue is a silent data-race risk. In Swift 6, if you mark the parameter `@Sendable`, the compiler checks the captures.
- Objective-C completion handlers: since Swift 6.2 (SE-0463), the completion-handler parameters of imported Objective-C methods are imported as `@Sendable`. The compiler can then diagnose non-`Sendable` captures inside them.

## Under the hood
The completion-handler version allocates a closure context for each level and enqueues work on GCD. The async version compiles into a **coroutine**. The function is split at each `await` into partial functions, and the local variables that are still needed after a suspension are stored in an **async frame** that the runtime allocates and manages. See [7.1](../07-internals/01-runtime.md).

## Exercises
1. Add a "retry up to 3 times on failure" policy to `fetchUser` in both styles. Count the lines.
2. In the callback version, introduce a bug that calls `completion` twice. Does anything warn you?
3. Can you introduce the equivalent bug in the async version?

<details><summary>Solutions</summary>

1. Async version:

<!-- check: lib -->
```swift
struct User: Sendable { let id: Int }
func fetchUser(id: Int) async throws -> User { User(id: id) }

func fetchUserWithRetry(id: Int) async throws -> User {
    var lastError: Error?
    for _ in 0..<3 {
        do { return try await fetchUser(id: id) } catch { lastError = error }
    }
    throw lastError!
}
```
The callback version needs a recursive helper that carries an attempt counter.

2. No. Nothing warns you, and the caller's handler runs twice.
3. No. A function can't return twice. The closest equivalent is resuming a continuation twice when you bridge an API ([1.2](../01-async-await/02-bridging-continuations.md)), and `CheckedContinuation` traps when that happens.
</details>

## Check yourself
1. Name three things a completion handler can't guarantee that `async` does.
2. Why did so much callback code contain `DispatchQueue.main.async`?

<details><summary>Answers</summary>

1. Any three of: that it completes exactly once; automatic error propagation; that the caller knows what isolation the code runs on; a standard cancellation mechanism; a lifetime tied to a scope.
2. The thread the callback ran on wasn't part of the API contract, and UIKit/AppKit must be used from the main thread.
</details>

## Further reading
- SE-0296 *Async/await* (the motivation section is excellent)
- SE-0463 *Import Objective-C completion handler parameters as `@Sendable`*
- WWDC21, *Meet async/await in Swift*
