# 6.2 App architecture under Swift 6

## Why it matters
In Swift 6, isolation is part of every type's API. An architecture that ignores it ends up with `@MainActor` everywhere (hitches), or `@unchecked Sendable` everywhere (races). This chapter lays out a layering that keeps each type in one clear isolation domain, with cheap boundaries between layers.

## Mental model

```
┌─────────────────────────────── @MainActor ───────────────────────────────┐
│  Views  ──▶  @Observable @MainActor models (UI state, intent methods)    │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │ await (values in: Sendable snapshots/DTOs)
┌───────────────────────────────────▼──────────────────────────────────────┐
│ Services: `Sendable` protocols                                           │
│   • stateless: structs (nonisolated; heavy work @concurrent)             │
│   • stateful:  actors (caches, sessions, coordinators)                   │
│   • persistence: a dedicated actor (e.g. SwiftData @ModelActor)          │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │
                         Networking / disk / system APIs
```

**Rule:** values crossing the boundaries are `Sendable` value types. Mutable reference types stay inside one domain.

## Core content

### Service protocols: `Sendable` and `async`
<!-- check: lib -->
```swift
import Foundation

struct Todo: Sendable, Identifiable, Codable { let id: UUID; var title: String; var done: Bool }

protocol TodoRepository: Sendable {
    func all() async throws -> [Todo]
    func save(_ todo: Todo) async throws
}
```

- **`Sendable`**, so the dependency can be held by a `@MainActor` model and still be used from other domains.
- **`async`** on every requirement, so conformers are free to be actors, to do I/O, or to be synchronous fakes ([1.4](../01-async-await/04-async-in-the-type-system.md)).
- **No isolation on the protocol**, so conformers choose their own.

### Conformers: an actor for state, a struct for stateless work
<!-- check: lib -->
```swift
import Foundation

struct Todo: Sendable, Identifiable, Codable { let id: UUID; var title: String; var done: Bool }
protocol TodoRepository: Sendable {
    func all() async throws -> [Todo]
    func save(_ todo: Todo) async throws
}

actor FileTodoRepository: TodoRepository {
    private let url: URL
    private var cache: [UUID: Todo]?

    init(url: URL) { self.url = url }

    func all() async throws -> [Todo] {
        if let cache { return Array(cache.values) }
        let loaded = try await Self.read(url)                 // I/O off the actor
        cache = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        return loaded
    }

    func save(_ todo: Todo) async throws {
        var all = try await all().reduce(into: [UUID: Todo]()) { $0[$1.id] = $1 }
        all[todo.id] = todo
        cache = all                                           // commit synchronously
        try await Self.write(Array(all.values), to: url)
    }

    @concurrent private static func read(_ url: URL) async throws -> [Todo] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Todo].self, from: Data(contentsOf: url))
    }
    @concurrent private static func write(_ todos: [Todo], to url: URL) async throws {
        try JSONEncoder().encode(todos).write(to: url, options: .atomic)
    }
}
```

Note the reentrancy discipline from [3.1](../03-isolation-and-actors/01-actors.md): `save` builds the new state and commits it to `cache` **before** the suspending write. Two concurrent saves can't lose each other's updates in the cache. (The *file* writes can still finish out of order. If that matters, serialize them, for example by chaining them through a stored `Task`.)

### The UI model
<!-- check: lib -->
```swift
import Foundation
import Observation

struct Todo: Sendable, Identifiable, Codable { let id: UUID; var title: String; var done: Bool }
protocol TodoRepository: Sendable {
    func all() async throws -> [Todo]
    func save(_ todo: Todo) async throws
}

@Observable @MainActor
final class TodoListModel {
    private(set) var todos: [Todo] = []
    private(set) var errorMessage: String?
    private let repository: any TodoRepository

    init(repository: any TodoRepository) { self.repository = repository }

    func load() async {
        do { todos = try await repository.all().sorted { $0.title < $1.title } }
        catch { errorMessage = error.localizedDescription }
    }

    func toggle(_ todo: Todo) async {
        var updated = todo
        updated.done.toggle()
        if let i = todos.firstIndex(where: { $0.id == todo.id }) { todos[i] = updated }   // optimistic update
        do { try await repository.save(updated) }
        catch {
            errorMessage = error.localizedDescription
            await load()                                                                 // roll back to the truth
        }
    }
}
```

### Test doubles: actors that record calls
<!-- check: output "saved 1, titles: [\"Write guide\"]" -->
```swift
import Foundation
import Observation

struct Todo: Sendable, Identifiable, Codable { let id: UUID; var title: String; var done: Bool }
protocol TodoRepository: Sendable {
    func all() async throws -> [Todo]
    func save(_ todo: Todo) async throws
}

actor FakeRepository: TodoRepository {
    private(set) var saved: [Todo] = []
    var stored: [Todo]
    init(_ todos: [Todo]) { stored = todos }
    func all() -> [Todo] { stored }                   // sync witnesses are fine
    func save(_ todo: Todo) { saved.append(todo) }
}

@Observable @MainActor final class TodoListModel {
    private(set) var todos: [Todo] = []
    private let repository: any TodoRepository
    init(repository: any TodoRepository) { self.repository = repository }
    func load() async { todos = (try? await repository.all()) ?? [] }
    func toggle(_ todo: Todo) async {
        var u = todo; u.done.toggle()
        try? await repository.save(u)
    }
}

@MainActor func test() async {
    let fake = FakeRepository([Todo(id: UUID(), title: "Write guide", done: false)])
    let model = TodoListModel(repository: fake)
    await model.load()
    await model.toggle(model.todos[0])
    let saved = await fake.saved
    print("saved \(saved.count), titles: \(model.todos.map(\.title))")
}

await test()
```

### Dependency injection without singletons
- Pass dependencies into initializers (as above). That's the simplest approach, and the compiler checks the isolation of everything you pass.
- For SwiftUI, put a `Sendable` dependency container in the `Environment`. A container that's a `struct` of `Sendable` protocol existentials is itself `Sendable`.
- **Avoid `static var shared` singletons with mutable state.** In Swift 6, they need `@MainActor`, an actor, or `nonisolated(unsafe)`, and the last one hides races.

### Boundary rules of thumb
1. **Snapshots out, intents in.** Services return `Sendable` value types. Models call intent methods (`save`, `toggle`), not fine-grained setters.
2. **Coarse actor APIs.** One `await` per user action, not one per property ([4.3](../04-sendable-and-safety/03-unchecked-mutex-atomics.md) measured the cost of a hop).
3. **Heavy work is explicitly `@concurrent`.** Never rely on "an async function runs in the background" ([3.4](../03-isolation-and-actors/04-approachable-concurrency.md)).
4. **One owner per mutable state.** If two domains need it, it belongs in an actor (or a `Mutex`), and the domains talk to that owner.

## Pitfalls & compiler errors
- **A `@MainActor` repository** forces all persistence work onto the main thread.
- **Passing a non-`Sendable` model object into a service** fails with `sending '…' risks causing data races`. Pass a value snapshot instead.
- **An actor per entity** (one actor per `Todo`) means too many hops, and invariants that span entities become impossible. Use actors per subsystem.

## Under the hood
`any TodoRepository` where the protocol refines `Sendable` makes the existential itself `Sendable`. That's why the `@MainActor` model can hold it and still `await` methods that run in the repository's own domain.

## Exercises
1. Serialize file writes in `FileTodoRepository` so they can never complete out of order (hint: a stored `Task` chain).
2. Write a `NetworkTodoRepository` struct (stateless) whose methods are `@concurrent`.
3. Add an in-memory cache actor in front of any `TodoRepository` (decorator pattern), coalescing concurrent `all()` calls ([3.1](../03-isolation-and-actors/01-actors.md)).

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
import Foundation

struct Todo: Sendable, Identifiable, Codable { let id: UUID; var title: String; var done: Bool }
protocol TodoRepository: Sendable {
    func all() async throws -> [Todo]
    func save(_ todo: Todo) async throws
}

actor WriteQueue {
    private var last: Task<Void, Never>?
    func enqueue(_ op: @escaping @Sendable () async -> Void) {
        let previous = last
        last = Task {
            await previous?.value          // wait for the previous write
            await op()
        }
    }
}

actor CachingRepository: TodoRepository {
    private let base: any TodoRepository
    private var inFlight: Task<[Todo], any Error>?
    private var cached: [Todo]?
    init(base: any TodoRepository) { self.base = base }

    func all() async throws -> [Todo] {
        if let cached { return cached }
        if let inFlight { return try await inFlight.value }
        let base = self.base
        let task = Task { try await base.all() }
        inFlight = task
        defer { inFlight = nil }
        let result = try await task.value
        cached = result
        return result
    }

    func save(_ todo: Todo) async throws {
        cached = nil
        try await base.save(todo)
    }
}
```
</details>

## Check yourself
1. Why should repository protocols be `Sendable` and have `async` requirements?
2. Where should JSON decoding of a large file run?
3. What's wrong with `actor TodoActor` (one per todo item)?

<details><summary>Answers</summary>

1. So that any isolation domain can hold and call them, and so that conformers can be actors, do I/O, or be sync fakes.
2. In a `@concurrent` function (or off any shared actor), not on the main actor or a busy service actor.
3. Every cross-item operation needs many hops, and invariants across items can't be enforced atomically.
</details>

## Further reading
- WWDC22, *Eliminate data races using Swift Concurrency*
- WWDC25, *Embracing Swift concurrency*
