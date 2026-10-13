# 4.1 `Sendable`, `@Sendable`, `sending`, and `~Sendable`

## Why it matters
Isolation decides *where* code runs. Sendability decides *what may cross* between isolation domains. Together they make up Swift 6's data-race safety. Every confusing Swift 6 error eventually comes down to one question: *is this value safe to share across this boundary?*

## Mental model

```
Two ways a value may cross an isolation boundary:

1. It is Sendable          — safe to SHARE: both sides may use it concurrently
                             (immutable value, value type of Sendables, actor, lock-protected class…)
2. It is `sending`         — safe to TRANSFER: the sender gives it up
   (disconnected region)     (non-Sendable, but nothing else references it)
```

`Sendable` is a property of a **type**. `sending` is a property of a **value at a specific point** in the program ([4.2](02-region-isolation.md)).

## Core content

### `Sendable` conformance: what's inferred, and what's checked (verified with 6.4)

<!-- check: lib -->
<!-- check: error "type 'Public' does not conform to the 'Sendable' protocol" -->
```swift
struct Internal { var x: Int }                 // non-public struct of Sendable fields → Sendable is INFERRED
public struct Public { public var x: Int }     // public → NOT inferred (it would become API you can't take back)
final class Holder { var x = 0 }
struct HasClass { let h: Holder }              // contains a non-Sendable class → not Sendable

func needs<T: Sendable>(_ t: T) {}

func probe(i: Internal, p: Public) {
    needs(i)       // ✅
    needs(p)       // ❌ type 'Public' does not conform to the 'Sendable' protocol
}
```

| Kind | How it becomes `Sendable` |
|---|---|
| struct / enum | implicitly, if it's non-`public` and all stored properties or associated values are `Sendable`; otherwise explicitly (and the compiler checks the fields) |
| `public` struct / enum | only explicitly, by writing `: Sendable` |
| class | explicitly, and only if it's `final`, has only immutable `let` stored properties of `Sendable` type, and has no superclass other than `NSObject` (SE-0302; the conformance must also be in the same source file) |
| actor | always |
| global-actor-isolated class | implicitly (all access goes through the actor, [3.2](../03-isolation-and-actors/02-global-actors.md)) |
| generic type | conditionally: `extension Box: Sendable where T: Sendable {}` |

Class errors, verified:
- `non-final class 'NotFinal' cannot conform to the 'Sendable' protocol`
- `stored property 'x' of 'Sendable'-conforming class 'C' is mutable`

### `@Sendable` function types
A closure that may run concurrently with its creator must be `@Sendable`. Inside it:
- Captured values must be `Sendable`.
- Captured `var`s can't be mutated: `mutation of captured var 'count' in concurrently-executing code [#SendableClosureCaptures]` (verified).

<!-- check: lib -->
```swift
func run(_ work: @escaping @Sendable () -> Void) {}

func ok() {
    let limit = 10                         // a `let` of a Sendable type: fine to capture
    run { print(limit) }
}
```

Methods and key paths can be inferred `@Sendable` too (SE-0418). For example, `array.map(\.id)` works in a concurrent context when the key path only references `Sendable` things.

### `sending`: transferring a non-`Sendable` value
`sending` (SE-0430) marks a parameter or result as *transferred*. The value must be in a **disconnected region**: nothing else may reference it after the transfer.

<!-- check: lib -->
```swift
final class Buffer { var bytes: [UInt8] = [] }      // NOT Sendable
actor Sink { func consume(_ b: Buffer) { _ = b.bytes.count } }

func makeBuffer() -> sending Buffer { Buffer() }    // the caller gets a fresh, disconnected value

@MainActor func pipeline(_ sink: Sink) async {
    let b = makeBuffer()
    b.bytes.append(1)          // still exclusively ours
    await sink.consume(b)      // ✅ transferred to the actor: we don't use `b` afterwards
}

func store(_ b: sending Buffer) {
    Task { b.bytes.append(3) } // ✅ a `sending` parameter can be captured by a Task
}
```

What happens if you use the value after transferring it:

<!-- check: lib -->
<!-- check: error "sending 'b' risks causing data races" -->
```swift
final class Buffer { var bytes: [UInt8] = [] }
actor Sink { func consume(_ b: Buffer) {} }

@MainActor func bad(_ sink: Sink) async {
    let b = Buffer()
    await sink.consume(b)
    b.bytes.append(2)          // ❌ used after the transfer
}
```

Verified diagnostics: `sending 'b' risks causing data races [#RegionIsolation::SendingRisksDataRace]`, with the notes *"sending 'b' to actor-isolated instance method 'consume' risks causing data races between actor-isolated and local main actor-isolated uses"* and *"access can happen concurrently"*.

Where `sending` shows up in the standard library (6.4 SDK): `Task.init(operation: sending …)`, the continuation `resume(returning: sending T)`, the `with*Continuation(…) -> sending T` functions, and `Disconnected` (accepted, not shipped, [4.2](02-region-isolation.md)).

### `~Sendable` (Swift 6.4, SE-0518)
Explicitly *suppresses* `Sendable`. It's useful in two cases: (a) documenting that a public type was audited and is deliberately non-`Sendable`, and (b) a base class that's non-`Sendable` while some subclasses are. It works in 6.4 without any flag (verified):

<!-- check: lib -->
<!-- check: error "type 'Opaque' does not conform to the 'Sendable' protocol" -->
```swift
func needs<T: Sendable>(_ t: T) {}

struct Opaque: ~Sendable { let v: Int }   // would otherwise be inferred Sendable
class Base: ~Sendable {}
final class ThreadSafe: Base, @unchecked Sendable {}   // ✅ allowed: `~Sendable` isn't inherited

func probe(o: Opaque) {
    needs(ThreadSafe())   // ✅
    needs(o)              // ❌
}
```

Compare this with the old way, `@available(*, unavailable) extension Base: Sendable {}`. That makes **all subclasses** permanently non-`Sendable`, too. SE-0518 also rules out `extension T: ~Sendable` (it must appear on the declaration), and `~Sendable` on protocols and generic parameters. To find public types that haven't been audited, enable `-Wwarning ExplicitSendable`. It produces, for example: `public struct 'P' does not specify whether it is 'Sendable' or not [#ExplicitSendable]` (verified).

### `SendableMetatype` (SE-0470)
`Sendable` is about *instances*. `SendableMetatype` is about the *type itself* (`T.self`) being usable from any isolation domain. That matters for static members and protocol conformances. `Sendable` refines it. You'll mostly meet it in generic code that calls static requirements from concurrent contexts, and in the default-isolation rules ([3.4](../03-isolation-and-actors/04-approachable-concurrency.md)).

## Pitfalls & compiler errors
- **Marking a type `Sendable` just to make an error go away.** If it's a class with mutable state, the compiler will reject it. That's when people reach for `@unchecked`. Stop and use an actor or `Mutex` instead ([4.3](03-unchecked-mutex-atomics.md)).
- **Making public types `Sendable` too early.** You can't remove the conformance later without breaking clients. Adding it later is fine.
- **Expecting a non-`Sendable` value to cross a boundary, when `sending` would have worked.** Check whether the value is disconnected ([4.2](02-region-isolation.md)).
- **Errors appear in stages.** Region-based (`sending`) errors are produced by a SIL pass that runs only after type checking succeeds. Fixing a type error can reveal new region errors (verified: in a file with both kinds, only the type error was reported until it was fixed).

## Under the hood
- `Sendable` is a **marker protocol**: the SDK declares `@_marker public protocol Sendable : SendableMetatype`. It has no witness table and no runtime representation. It's purely a compile-time constraint. Verified: `x is any Sendable` fails to compile with `marker protocol 'Sendable' cannot be used in a conditional cast`.
- `@Sendable` *is* part of the function type, and so is `sending`: `(sending T) -> Void` and `(T) -> Void` are different types.
- `sending` doesn't change the calling convention much. Its effect is on the *caller's* region analysis: the argument's region is considered transferred after the call.

## Exercises
1. Make `struct Page<Item> { var items: [Item] }` conditionally `Sendable`.
2. Rewrite a function that returns a fresh non-`Sendable` `NSMutableArray`, so that its callers can send the result to an actor.
3. A `public final class Config` has only `let` properties of type `String`. Should it be `Sendable`? What does adding the conformance commit you to?

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
import Foundation

struct Page<Item> { var items: [Item] }
extension Page: Sendable where Item: Sendable {}

func makeList() -> sending NSMutableArray {     // tells callers: disconnected, transferable
    NSMutableArray()
}

actor Store { func keep(_ a: NSMutableArray) {} }
func use(_ s: Store) async {
    let list = makeList()
    list.add(1)
    await s.keep(list)                           // ✅ transferred
}

public final class Config: Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}
```
3. Yes, it qualifies. The commitment is that you can never add mutable state or a non-`Sendable` stored property without breaking clients, unless you add internal synchronization and switch to `@unchecked Sendable`.
</details>

## Check yourself
1. Is `public struct P { let x: Int }` `Sendable`?
2. What's the difference between `Sendable` and `sending`?
3. Can a subclass of a `~Sendable` class conform to `Sendable`?

<details><summary>Answers</summary>

1. Not implicitly. Public types need an explicit conformance.
2. `Sendable` is a property of a type, meaning it's safe to share. `sending` is a property of a value at a specific point, meaning it's safe to transfer ownership of it.
3. Yes, with `@unchecked Sendable` (verified). That's exactly what `~Sendable` allows and `@available(*, unavailable)` doesn't.
</details>

## Further reading
- SE-0302 *`Sendable` and `@Sendable` closures*
- SE-0418 *Inferring `Sendable` for methods and key path literals*
- SE-0430 *`sending` parameter and result values*
- SE-0518 *`~Sendable` for explicitly marking non-`Sendable` types*
