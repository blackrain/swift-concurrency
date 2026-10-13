# 4.2 Region-based isolation: how the compiler reasons about non-`Sendable` values

## Why it matters
Swift 6.0 can pass **non-`Sendable`** values across isolation boundaries when it can prove that's safe. The analysis behind this (SE-0414) explains why some code compiles and nearly identical code doesn't. Once you can reason in regions, `sending '…' risks causing data races` stops being mysterious.

## Mental model
Every non-`Sendable` value belongs to an **isolation region**: a group of values that might reference each other. (`Sendable` values don't belong to any region and are never tracked.)

```
let x = Node()        regions: {x}            ← disconnected (fresh value, no references in or out)
let y = Node()        regions: {x} {y}
x.next = y            regions: {x, y}         ← MERGED: y is now reachable from x
await actor.take(x)   regions: {x, y}→actor   ← the WHOLE region is transferred
y.next = nil          ❌ y belongs to the transferred region
```

A region can be in one of these states (SE-0414, *Taxonomy of Isolation Regions*):
- **disconnected**: not tied to any isolation domain, so it can be transferred;
- **actor-isolated**: reachable from an actor's state, or from a global actor's state; never transferable;
- **task-isolated**: reachable from a nonisolated async function's parameters; it belongs to the caller, so it can't be transferred;
- **invalid**: control flow merged conflicting regions.

## Core content

### Merging rules (from SE-0414, each verified below)
Regions merge whenever the program *might* create an alias:
1. **Assignment through a property** (`x.next = y`) merges `y`'s region into `x`'s.
2. **A function call** merges the regions of *all its non-`Sendable` arguments* (and its non-`Sendable` result), because the compiler can't see what the callee does with them.
3. **Capturing a value in a closure** merges the value into the closure's region.

<!-- check: lib -->
<!-- check: error "sending 'x' risks causing data races" -->
```swift
final class Node { var next: Node? }
actor A { func take(_ n: Node) {} }

func link(_ a: Node, _ b: Node) {}         // the body doesn't matter: the compiler assumes the worst

func viaCall(a: A) async {
    let x = Node(), y = Node()
    link(x, y)                             // rule 2: x and y are now in one region
    await a.take(x)                        // transfers {x, y}
    y.next = nil                           // ❌ sending 'x' risks causing data races
}
```

The same code without the `link(x, y)` call compiles, because `x` and `y` stay in separate regions (verified):

<!-- check: lib -->
```swift
final class Node { var next: Node? }
actor A { func take(_ n: Node) {} }

func separate(a: A) async {
    let x = Node(), y = Node()
    await a.take(x)                        // transfers {x} only
    y.next = nil                           // ✅ y is in its own region
}
```

> A detail I hit while verifying: `_ = y` after the transfer is **not** a use, and doesn't trigger the error. `y.next = nil` is a use.

### Parameters are task-isolated
A non-`Sendable` parameter of a nonisolated function belongs to the **caller**, which might keep using it. So it can't be transferred:

<!-- check: lib -->
<!-- check: error "sending 'n' risks causing data races" -->
```swift
final class Node { var next: Node? }
actor A { func take(_ n: Node) {} }

func forward(n: Node, a: A) async {
    await a.take(n)          // ❌ 'n' belongs to the caller's region
}
```

Verified note: *"sending 'n' to actor-isolated instance method 'take' risks causing data races between actor-isolated code and code in the current isolation context"*. The fix is to declare that the caller gives up the value:

<!-- check: lib -->
```swift
final class Node { var next: Node? }
actor A { func take(_ n: Node) {} }

func forward(n: sending Node, a: A) async {
    await a.take(n)          // ✅ the caller must pass a disconnected value
}
```

### Actor-isolated regions never leave
A non-`Sendable` value stored in an actor's state, or reachable from it, is in that actor's region. It can't be sent anywhere. That's the `self.log` case from [3.3](../03-isolation-and-actors/03-isolation-domains.md). Your options:
- keep the work on the actor: use `nonisolated(nonsending)`, or an `isolated` parameter;
- copy the data into a `Sendable` value (for example, a struct snapshot) and send that;
- make the type `Sendable`.

### Returning disconnected values: `sending` results
By default, a non-`Sendable` value returned from an actor method is in the actor's region, and the caller can't receive it across the boundary. Marking the result `sending` promises that the returned value is disconnected:

<!-- check: lib -->
```swift
final class Report { var lines: [String] = [] }

actor Generator {
    func make() -> sending Report {        // must return a fresh, disconnected value
        let r = Report()
        r.lines.append("ok")
        return r
    }
}

@MainActor func show(_ g: Generator) async {
    let report = await g.make()            // ✅ received on the main actor
    report.lines.append("viewed")
}
```

### Control flow
Region analysis is **flow-sensitive**. A transfer on one branch makes the value unusable afterwards, unless every path that reaches the use is safe. The compiler reports the use and the transfer point as separate notes. Read both.

### `Disconnected<T>` (SE-0538): accepted, **not shipped in 6.4**
`sending` works only at function boundaries. It can't be stored in a property or a generic container. SE-0538 proposes a `Disconnected<Value>` wrapper that keeps the "disconnected" property through storage, with `consume() -> sending Value`. As of October 2026, its status is *Accepted*, but the type is neither in the Swift 6.4 SDK nor on `main` (verified by searching both). Until it ships, you have three options: use `sending` at each boundary, use `nonisolated(unsafe)` locally after convincing yourself it's safe, or redesign the data as `Sendable`.

## Pitfalls & compiler errors
| Diagnostic | Usual cause | Fix |
|---|---|---|
| `sending 'x' risks causing data races` + "…between actor-isolated and local … uses" | `x` (or something in its region) is used after the transfer | stop using it, or send a copy |
| same + "…code in the current isolation context" on a parameter | transferring a task-isolated parameter | make the parameter `sending` |
| `sending value of non-Sendable type '…' risks causing data races` on a closure passed to `Task` | the closure captures something that's used again afterwards | don't touch the captured values after creating the task ([0.2](../00-foundations/02-races-deadlocks-inversion.md)) |
| `passing closure as a 'sending' parameter risks causing data races…` | the closure captures mutable local state | return values instead of mutating shared state |

## Under the hood
- Region analysis runs on SIL, in the mandatory `SendNonSendable` diagnostic pass (`lib/SILOptimizer/Mandatory/SendNonSendable.cpp`), after type checking. That's why these errors appear only once type errors are fixed, and why `swiftc -typecheck` never reports them (verified in [0.2](../00-foundations/02-races-deadlocks-inversion.md): a `-typecheck`-only check missed them entirely).
- The analysis is intraprocedural. Function signatures (`sending`, `isolated`, `Sendable`) are the only contract between functions. That's why the merge rule for calls is conservative.
- SE-0414 calls the caller's continued ownership after a send a *weak transfer*: the value's lifetime still ends in the caller (its `deinit` may run there), but the caller can't *use* it.

## Exercises
1. Fix `viaCall` above in two different ways.
2. Write an actor method that builds a non-`Sendable` `NSMutableAttributedString` and returns it to the main actor.
3. Why can't `func forward(n: Node, a: A) async` transfer `n`, while `func forward(n: sending Node, a: A)` can? Explain it in terms of who owns the region.

<details><summary>Solutions</summary>

<!-- check: lib -->
```swift
import Foundation

final class Node { var next: Node? }
actor A { func take(_ n: Node) {} }
func link(_ a: Node, _ b: Node) {}

func fix1(a: A) async {                    // don't link them
    let x = Node(), y = Node()
    await a.take(x)
    y.next = nil
}

func fix2(a: A) async {                    // or: don't use y after sending the region
    let x = Node(), y = Node()
    link(x, y)
    y.next = nil
    await a.take(x)
}

actor Formatter {
    func build() -> sending NSMutableAttributedString {
        NSMutableAttributedString(string: "Hello")
    }
}
@MainActor func display(_ f: Formatter) async {
    let s = await f.build()
    s.append(NSAttributedString(string: "!"))
}
```
3. A plain parameter is in a task-isolated region owned by the caller, who may keep using it after the call returns. A `sending` parameter obliges the *caller* to pass a disconnected value and give it up, so the callee owns the region.
</details>

## Check yourself
1. `let a = NS(); let b = NS(); f(a, b)`. Are `a` and `b` in the same region afterwards?
2. Can a non-`Sendable` property of an actor ever be sent to another domain?
3. Why don't `Sendable` values participate in region analysis?

<details><summary>Answers</summary>

1. Yes. A call merges the regions of all its non-`Sendable` arguments.
2. Not directly. It's in the actor's region. You can send a copy or a `Sendable` snapshot.
3. They're safe to share, so there's no aliasing to track.
</details>

## Further reading
- SE-0414 *Region based Isolation*
- SE-0430 *`sending` parameter and result values*
- SE-0538 *Disconnected* (accepted)
