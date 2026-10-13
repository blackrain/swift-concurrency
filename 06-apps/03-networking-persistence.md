# 6.3 Networking and persistence

## Why it matters
Networking and persistence are where most app concurrency lives, and where the frameworks carry their own isolation rules. `URLSession` is already async and cancellation-aware. SwiftData and Core Data have **contexts that must never cross isolation domains**. Getting this wrong means compile errors, or crashes from contexts used on the wrong thread.

## Mental model

```
Networking:   any isolation ──await──▶ URLSession (its own queues) ──▶ Sendable Data/response back
Persistence:  ModelContainer (Sendable, shared)
                ├── mainContext            → @MainActor (UI reads)
                └── @ModelActor actor      → its own ModelContext (background writes)
              cross the boundary with PersistentIdentifier (Sendable), never with model objects
```

## Core content

### URLSession

<!-- check: lib -->
```swift
import Foundation

enum APIError: Error { case badStatus(Int), decoding(any Error) }

struct APIClient: Sendable {
    let session: URLSession
    let base: URL

    @concurrent
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type = T.self) async throws -> T {
        let (data, response) = try await session.data(from: base.appending(path: path))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decoding(error) }
    }

    func lines(_ path: String) async throws -> [String] {
        var out: [String] = []
        let (bytes, _) = try await session.bytes(from: base.appending(path: path))
        for try await line in bytes.lines { out.append(line) }   // streaming
        return out
    }
}
```

Verified facts:
- **Cancelling the task cancels the request.** `URLSession.data(from:)` throws `URLError` with code `-999` (`.cancelled`), not `CancellationError` ([1.3](../01-async-await/03-errors-typed-throws-defer.md)).
- `URLSession` is `Sendable`, so a `struct` client holding one is `Sendable` too.
- Mark the decode-heavy method `@concurrent`, so JSON decoding never lands on the main actor, regardless of `NonisolatedNonsendingByDefault`.

Other async APIs: `data(for: URLRequest)`, `upload(for:from:)`, `download(from:)`, and `bytes(from:)` for streaming. Each takes an optional per-task `delegate:` (for example, for authentication challenges or progress).

### SwiftData: `@ModelActor`
Verified in the macOS 27 SDK:
- `ModelContainer`: `Sendable`. Share one container.
- `PersistentIdentifier`: `Sendable`. It's the currency for crossing domains.
- `ModelContext`: **not `Sendable`**. The SDK says so explicitly: `conformance of 'ModelContext' to 'Sendable' is unavailable: contexts cannot be shared across concurrency contexts`.
- `@Model` classes aren't `Sendable`.

<!-- check: output "imported on actor, read on main: [\"a\", \"b\", \"c\"]" -->
```swift
import SwiftData
import Foundation

@Model final class Note {
    var title: String
    init(title: String) { self.title = title }
}

@ModelActor
actor Importer {                                   // gets its own modelContext and serial executor
    func importNotes(_ titles: [String]) throws -> [PersistentIdentifier] {
        let notes = titles.map { Note(title: $0) }
        notes.forEach { modelContext.insert($0) }
        try modelContext.save()
        return notes.map(\.persistentModelID)      // return IDs, not models
    }
}

@MainActor func run() async throws {
    let container = try ModelContainer(for: Note.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let importer = Importer(modelContainer: container)
    let ids = try await importer.importNotes(["a", "b", "c"])
    let titles = ids.compactMap { (container.mainContext.model(for: $0) as? Note)?.title }
    print("imported on actor, read on main:", titles)
}

try await run()
```

Returning the `Note` object itself fails, as it should:

<!-- check: lib -->
<!-- check: error "non-Sendable 'Note'-typed result can not be returned from actor-isolated instance method 'make()' to main actor-isolated context" -->
```swift
import SwiftData

@Model final class Note { var title: String; init(title: String) { self.title = title } }

@ModelActor actor Importer {
    func make() -> Note {
        let n = Note(title: "x"); modelContext.insert(n); return n
    }
}

@MainActor func use(_ i: Importer) async {
    let n = await i.make()        // ❌ [#RegionIsolation]
    print(n.title)
}
```

The `@ModelActor` macro generates `modelExecutor`, `modelContainer` and `init(modelContainer:)`, and conforms the actor to the `ModelActor` protocol (macro declaration in `SwiftData.swiftinterface`). The actor runs on an executor tied to its model context.

### Core Data
`NSManagedObjectContext.perform` has an async form: `perform<T>(schedule: .immediate, _ block: @escaping @Sendable () throws -> T) async rethrows -> T` (marked `@preconcurrency` in the SDK). Use it to hop onto the context's queue, and pass `NSManagedObjectID`s (not `NSManagedObject`s) between contexts:

<!-- check: lib -->
```swift
import CoreData

func titles(in context: NSManagedObjectContext) async throws -> [String] {
    try await context.perform {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Note")
        return try context.fetch(request).compactMap { $0.value(forKey: "title") as? String }
    }   // only Sendable values ([String]) leave the closure
}
```

## Pitfalls & compiler errors
- **Passing `@Model` / `NSManagedObject` instances across actors.** Pass `PersistentIdentifier` / `NSManagedObjectID`, and re-fetch on the other side.
- **Doing all writes on `mainContext`.** It's main-actor-bound, so large imports cause hitches. Use a `@ModelActor`.
- **Treating `URLError.cancelled` as a user-visible failure.**
- **Decoding in a nonisolated `async` function under `NonisolatedNonsendingByDefault`, called from the main actor.** It now runs **on** the main actor. Use `@concurrent`.

## Under the hood
- `URLSession` is closed source, so we can only observe its behavior: cancelling the awaiting Swift task cancels the underlying `URLSessionTask`, which then fails with `URLError.cancelled` (-999). That's the same error code you get from calling `cancel()` on a data task directly.
- The `ModelActor` protocol requires `nonisolated var modelExecutor: any ModelExecutor`, where `ModelExecutor: Executor` holds the `modelContext` (there's also a `SerialModelExecutor: SerialExecutor`). The actor's isolated methods run on that executor, which is how SwiftData ties the actor to its context ([7.2](../07-internals/02-executors.md) covers custom executors).

## Exercises
1. Add retry with exponential backoff to `APIClient.get`, but don't retry when the task is cancelled.
2. Write a `@ModelActor` method that deletes notes whose titles match a predicate, and returns the number deleted.
3. Download a large file with `download(from:)`, and move it into the caches directory before the method returns. Why must the move happen before returning?

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
import Foundation
import SwiftData

func withBackoff<T: Sendable>(attempts: Int = 3, _ op: @Sendable () async throws -> T) async throws -> T {
    var delay = Duration.milliseconds(200)
    for attempt in 1...attempts {
        do { return try await op() }
        catch let e as URLError where e.code == .cancelled { throw e }
        catch is CancellationError { throw CancellationError() }
        catch where attempt < attempts {
            try await Task.sleep(for: delay)        // throws if cancelled during the wait
            delay *= 2
        }
    }
    return try await op()
}

@Model final class Note { var title: String; init(title: String) { self.title = title } }

@ModelActor actor Cleaner {
    func delete(containing text: String) throws -> Int {
        let all = try modelContext.fetch(FetchDescriptor<Note>())
        let doomed = all.filter { $0.title.contains(text) }
        doomed.forEach { modelContext.delete($0) }
        try modelContext.save()
        return doomed.count
    }
}

func fetchToCache(_ url: URL) async throws -> URL {
    let (tmp, _) = try await URLSession.shared.download(from: url)
    let dest = URL.cachesDirectory.appending(path: url.lastPathComponent)
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: tmp, to: dest)
    return dest
}
```
3. The returned URL points to a temporary file that you don't own, so its lifetime is up to the system. Moving it into a location you control before returning makes the result independent of that lifetime. (Read the `download(from:delegate:)` documentation for the exact guarantee your SDK makes.)
</details>

## Check yourself
1. Which SwiftData types can cross isolation boundaries?
2. What error does a cancelled `URLSession.data(from:)` throw?
3. Why mark the decoding method `@concurrent` explicitly?

<details><summary>Answers</summary>

1. `ModelContainer` and `PersistentIdentifier`. `ModelContext` and `@Model` objects can't.
2. `URLError` with code `.cancelled` (-999).
3. Under `NonisolatedNonsendingByDefault`, a plain async function runs on its caller's actor, which may be the main actor. `@concurrent` guarantees that it runs off the caller's actor.
</details>

## Further reading
- Apple Developer Documentation: `ModelActor`, `URLSession`
- WWDC23, *Meet SwiftData*
