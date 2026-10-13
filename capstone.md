# Capstone: an offline-first feed app

Build a small SwiftUI app (iOS 27 / macOS 27 deployment, Swift 6 language mode) that exercises every part of this guide. The deliverable is the app plus a short write-up that answers the review questions at the end.

## Requirements

### Features
1. **Feed list.** Load articles from a JSON endpoint (or a local mock server). Show cached articles immediately, then refresh in the background.
2. **Search.** Use a debounced (300 ms) search field. The previous search is cancelled when the query changes. Stale results must never overwrite fresh ones.
3. **Thumbnails.** Download and decode images off the main actor. Concurrent requests for the same URL share one download. Cap downloads at 4 concurrent.
4. **Offline persistence.** Store articles with SwiftData through a `@ModelActor`. The UI reads from the main context.
5. **Live updates.** A simulated "push" source (`AsyncStream`) inserts new articles. The list updates without a manual refresh.
6. **Settings.** An `@Observable` settings object. Changing "show images" is observed by the feed model through `Observations`.
7. **Graceful cleanup.** Leaving the feed cancels all of its work. A "sync on exit" step runs to completion even when the task has been cancelled (cancellation shield + async `defer`).

### Constraints
- Build settings: `SWIFT_VERSION = 6`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
- **Zero** `@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency` in your own code, unless each one has a comment justifying it.
- No `DispatchSemaphore`, `DispatchGroup.wait`, or blocking I/O in async code.
- Time-dependent logic (debounce, retry, timeouts) takes an injected `Clock`.

### Tests (Swift Testing)
- Debounce and cancellation with a `ManualClock` (no real sleeps).
- Thumbnail coalescing: 10 concurrent requests → 1 download.
- Persistence: an import on the `@ModelActor` is visible through the main context, by `PersistentIdentifier`.
- The whole suite passes under `--sanitize=thread`, and with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` set.

## Suggested architecture
```
@MainActor           FeedModel, SearchModel, SettingsModel (@Observable)
Sendable services    APIClient (struct, @concurrent decode), Clock injection
actors               ThumbnailCache (in-flight coalescing), FeedStore (@ModelActor)
streams              PushSource → AsyncStream<Article> (bufferingNewest), CommandProcessor for ordered writes
```

A compiling skeleton of the boundaries (build it out from here):

<!-- check: lib -->
<!-- check: flags -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances -->
```swift
import Foundation
import Observation
import SwiftData

nonisolated struct ArticleDTO: Codable, Sendable, Identifiable { let id: Int; let title: String; let imageURL: URL? }

nonisolated protocol ArticleAPI: Sendable {
    func articles(query: String?) async throws -> [ArticleDTO]
}

nonisolated struct HTTPArticleAPI: ArticleAPI {
    let session: URLSession
    let base: URL
    @concurrent func articles(query: String?) async throws -> [ArticleDTO] {
        var url = base.appending(path: "articles")
        if let query { url.append(queryItems: [URLQueryItem(name: "q", value: query)]) }
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode([ArticleDTO].self, from: data)
    }
}

@Model final class StoredArticle {
    @Attribute(.unique) var remoteID: Int
    var title: String
    init(remoteID: Int, title: String) { self.remoteID = remoteID; self.title = title }
}

@ModelActor
actor FeedStore {
    func upsert(_ dtos: [ArticleDTO]) throws {
        for dto in dtos { modelContext.insert(StoredArticle(remoteID: dto.id, title: dto.title)) }
        try modelContext.save()
    }
}

actor ThumbnailCache {
    private var inFlight: [URL: Task<Data, any Error>] = [:]
    func data(for url: URL, session: URLSession) async throws -> Data {
        if let task = inFlight[url] { return try await task.value }
        let task = Task { try await session.data(from: url).0 }
        inFlight[url] = task
        return try await task.value
    }
}

@Observable
final class FeedModel {                                   // @MainActor by default isolation
    private(set) var articles: [ArticleDTO] = []
    private let api: any ArticleAPI
    private let store: FeedStore
    init(api: any ArticleAPI, store: FeedStore) { self.api = api; self.store = store }

    func refresh() async {
        guard let fresh = try? await api.articles(query: nil) else { return }
        articles = fresh
        try? await store.upsert(fresh)
    }
}
```

## Review questions for your write-up
1. For each type: what is its isolation, and why?
2. List every place where a value crosses an isolation boundary, and why it's safe (`Sendable`, `sending`, or a snapshot).
3. For each actor method that contains an `await`: what state could change across that `await`, and how does your code cope?
4. Which tasks are unstructured? Who owns each one, and when is it cancelled?
5. Where does CPU-heavy work run? How did you verify that it never lands on the main actor (Instruments)?
6. What did TSan and `POOL_STRICT=1` find?
7. Which Swift 6.4 / OS 27 features did you use (shields, `withContinuation`, `withContinuousObservation`)? What would you do to support OS 26?
