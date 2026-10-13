# 6.1 SwiftUI and concurrency

## Why it matters
Most concurrency code in an iOS or macOS app starts in a view: loading data when a screen appears, reacting to input, refreshing. SwiftUI's `.task` modifier gives that work a **structured lifetime tied to the view**. Getting this right removes most `onAppear { Task { … } }` bugs: leaked work, duplicate loads, and updates to views that are already gone.

## Mental model

```
view appears ──▶ .task starts (on the main actor, inheriting the view's isolation)
view disappears ──▶ the task is CANCELLED
.task(id: x): x changes ──▶ the old task is CANCELLED, a new one STARTS
```

The view's lifetime is the task's scope. It's the UI equivalent of structured concurrency.

## Core content

### Verified behavior
I hosted a SwiftUI view in an AppKit window (macOS 27 SDK, Swift 6.4). It changed a `.task(id:)` value after 300 ms, and removed the view after another 300 ms. The log:

```
start a main=true       ← the task body ran on the main thread (the view is @MainActor)
start b main=true       ← the id changed: the new task STARTED…
cancelled a             ← …and only then did the old task observe its cancellation
cancelled b             ← the view was removed: its task was cancelled
```

Note the ordering: **the new task may start before the old task finishes its cancellation handling.** If both write to shared state, guard against stale results (see the pattern below).

### The signatures (macOS 27 SDK)
<!-- check: skip -->
```swift
nonisolated func task(name: String? = nil, priority: TaskPriority = .userInitiated,
                      file: String = #fileID, line: Int = #line,
                      @_inheritActorContext _ action: sending @escaping @isolated(any) () async -> Void) -> some View

nonisolated func task<T: Equatable>(id: T, name: String? = nil, priority: TaskPriority = .userInitiated, …,
                      @_inheritActorContext _ action: sending @escaping @isolated(any) () async -> Void) -> some View
```

- The default priority is **`.userInitiated`**.
- `@_inheritActorContext`: the closure runs on the main actor, because `View` is `@MainActor` ([3.2](../03-isolation-and-actors/02-global-actors.md)).
- On OS 26.4+, unnamed tasks are automatically named `"View.task @ <file>:<line>"`, which shows up in debugging tools. There's also an overload that takes an `executorPreference:` ([7.2](../07-internals/02-executors.md)).
- `.refreshable(action:)` takes an `@_inheritActorContext @Sendable () async -> Void` action, so it also runs on the main actor.

### The standard screen pattern

<!-- check: lib -->
```swift
import SwiftUI

struct Article: Identifiable, Sendable { let id: Int; let title: String }

protocol ArticleService: Sendable {
    func articles(matching query: String) async throws -> [Article]
}

@Observable @MainActor
final class SearchModel {
    var query = ""
    private(set) var results: [Article] = []
    private(set) var error: String?
    private let service: any ArticleService

    init(service: any ArticleService) { self.service = service }

    func search() async {
        let q = query                                    // capture the input at start
        do {
            try await Task.sleep(for: .milliseconds(300))   // debounce: cancelled if the query changes
            let found = try await service.articles(matching: q)
            guard q == query else { return }             // a stale result: a newer query is active
            results = found
            error = nil
        } catch is CancellationError {
            // superseded by a newer query or the view disappeared: not an error
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SearchView: View {
    @State private var model: SearchModel
    init(service: any ArticleService) { _model = State(initialValue: SearchModel(service: service)) }

    var body: some View {
        List(model.results) { Text($0.title) }
            .searchable(text: $model.query)
            .task(id: model.query) { await model.search() }   // restart (and debounce) on every keystroke
            .refreshable { await model.search() }
    }
}
```

Why this works:
- `.task(id: model.query)` cancels the previous search when the query changes. The `Task.sleep` acts as a debounce: it throws `CancellationError` if the user keeps typing.
- The model is `@MainActor`, so `results` and `error` are mutated on the main actor, and SwiftUI observes them.
- The service is `Sendable` and runs its own work wherever it wants. Its `async` method can be `@concurrent`, or isolated to an actor.
- The `guard q == query` check handles the ordering subtlety from the experiment above.

### Button actions: when you need `Task {}`
Button actions are synchronous, so starting async work there needs a `Task`. That task is **not** cancelled when the view disappears, so store it in the model if it matters:

<!-- check: lib -->
```swift
import SwiftUI

@Observable @MainActor final class UploadModel {
    private(set) var isUploading = false
    private var upload: Task<Void, Never>?

    func start() {
        upload?.cancel()
        isUploading = true                               // synchronous: renders on this turn
        upload = Task {
            defer { isUploading = false }
            try? await Task.sleep(for: .seconds(1))      // stands in for the upload
        }
    }
    func cancel() { upload?.cancel() }
}

struct UploadButton: View {
    let model: UploadModel
    var body: some View {
        Button(model.isUploading ? "Cancel" : "Upload") {
            model.isUploading ? model.cancel() : model.start()
        }
    }
}
```

### `.task` vs. `onAppear { Task { } }`
| `.task { }` | `onAppear { Task { } }` |
|---|---|
| cancelled automatically when the view disappears | runs to completion even after the view is gone |
| restarts with `.task(id:)` | you have to manage restarts yourself |
| structured: easy to reason about | a leak risk: the closure captures the view's state |

**Use `.task`.** Use `Task {}` only in event handlers, and own the handle.

## Pitfalls & compiler errors
- `class property 'isMainThread' is unavailable from asynchronous contexts; Work intended for the main actor should be marked with @MainActor` (verified). Don't check threads in async code. Use isolation.
- **Heavy work directly inside `.task`** runs on the main actor and blocks the UI. Move it into a `@concurrent` function or an actor.
- **Swallowing `CancellationError` as a user-facing error** shows "cancelled" alerts on every keystroke.
- **Stale writes** when an old task finishes after a new one has started. Compare against the current input, or keep a request token.

## Under the hood
- On OS 26.4+, `.task` creates a `_TaskModifier2` / `_TaskValueModifier2` (on older OSes, `_TaskModifier` / `_TaskValueModifier`), visible in the `@export(implementation)` bodies in `SwiftUI.swiftinterface`. The modifier starts the task when the view appears, and cancels it on disappearance or when `id` changes.
- Because the action is `@isolated(any)`, SwiftUI's task starts directly on the main actor's executor ([3.3](../03-isolation-and-actors/03-isolation-domains.md)).

## Exercises
1. Add pagination to `SearchModel`: `loadMore()` appends the next page, must not run twice concurrently, and must be cancelled when the query changes.
2. Rewrite a view that does `onAppear { Task { await model.load() } }` to use `.task`. What changes about navigation back and forth?
3. A detail view loads a large image. Make sure decoding happens off the main actor, while assignment to the model happens on it.

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
import SwiftUI

struct Page: Sendable { let items: [String]; let next: Int? }

@Observable @MainActor final class Feed {
    private(set) var items: [String] = []
    private var nextPage: Int? = 0
    private var loading: Task<Void, Never>?

    func reset() { loading?.cancel(); loading = nil; items = []; nextPage = 0 }

    func loadMore() {
        guard loading == nil, let page = nextPage else { return }   // no concurrent loads
        loading = Task {
            defer { loading = nil }
            guard let result = try? await Self.fetch(page: page), !Task.isCancelled else { return }
            items += result.items
            nextPage = result.next
        }
    }

    @concurrent nonisolated static func fetch(page: Int) async throws -> Page {
        try await Task.sleep(for: .milliseconds(50))
        return Page(items: ["item \(page)"], next: page < 5 ? page + 1 : nil)
    }
}

@Observable @MainActor final class ImageModel {
    private(set) var image: CGImage?
    func load(_ data: Data) async {
        image = await Self.decode(data)                   // decode off-main, assign on-main
    }
    @concurrent nonisolated static func decode(_ data: Data) async -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
```
2. With `.task`, leaving the screen cancels the load, and coming back starts a fresh one. With `onAppear { Task { } }`, loads pile up and can finish after the user has left.
</details>

## Check yourself
1. Which isolation does the `.task` closure in a SwiftUI view run on?
2. What happens to a `.task(id:)` task when its `id` changes?
3. Is a `Task {}` started in a button action cancelled when the view disappears?

<details><summary>Answers</summary>

1. The main actor (it inherits the view's `@MainActor` isolation; verified: `main=true`).
2. It's cancelled, and a new task starts. The new one can start before the old one finishes handling the cancellation.
3. No. You have to keep the handle and cancel it yourself.
</details>

## Further reading
- Apple Developer Documentation: `View.task(priority:_:)`, `View.task(id:priority:_:)`
- WWDC21, *Discover concurrency in SwiftUI*
