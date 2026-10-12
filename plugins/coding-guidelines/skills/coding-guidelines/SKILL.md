---
name: coding-guidelines
description: Use when writing, refactoring or reviewing C# code that must follow the team's coding guidelines — rules of thumb (least surprise, KISS, YAGNI, DRY) plus concrete rules for class and member design, naming, maintainability (at most 7 statements per method, private/internal sealed by default, no magic numbers), exceptions and events, async vs Task.Run, framework usage, comments and layout. Also when asked whether code "follows our guidelines", for a guideline-based code review, or for an .editorconfig that enforces them. Not for modern C# feature advice such as records, pattern matching or Span<T> (use modern-csharp-coding-standards), and not for test-method naming, which has separate guidelines.
---

# Coding guidelines

Team guidelines for understandable, maintainable C#. They are partly based on a 2018 talk on coding
guidelines by Dennis Vroegop; where they say nothing, follow Microsoft's
[C# coding conventions](https://learn.microsoft.com/dotnet/csharp/fundamentals/coding-style/coding-conventions)
and [.NET naming guidelines](https://learn.microsoft.com/dotnet/standard/design-guidelines/naming-guidelines).

They are guidelines, not laws: when one clearly does not help in a specific case, say so and explain why
(the team agrees exceptions with the lead developer). Do not swap one for a "faster" approach just because
it is shorter; the guideline usually exists because of a downside that is easy to overlook.

## How to apply

- **Writing or refactoring code:** follow every rule below. Where the existing code breaks a rule, match the
  rule in new code, and only fix old code that the task touches.
- **Reviewing code:** report each violation as `file:line — rule — what to change`, most important first
  (correctness-affecting rules such as swallowed exceptions or null collections before style). Do not report
  rules the code already meets.
- **Unsure whether an exception is justified:** name the rule, explain the trade-off, and leave the decision
  to the user.

## Rules of thumb

Most concrete rules below are applications of these four.

- **Principle of least surprise.** A name, method or component should do exactly what a reader expects from
  how it looks. Every wrong assumption a colleague makes costs time.
- **KISS (keep it simple).** Simplicity is a goal, not a shortcoming. The simpler the code, the cheaper it is
  to understand, maintain and extend.
- **YAGNI (you aren't gonna need it).** Do not build for requirements that do not exist yet. Deliver what is
  needed now; it avoids over-engineering and the complexity that comes with it.
- **DRY (don't repeat yourself).** Do not copy and paste code. Even two or three repeated lines belong in a
  method, type or other reusable element, so a later change happens in one place.

## Class design

- **A class or interface has a single purpose.** Do not bundle several processes in one type; its name must
  explain what it does.
- **A base class never refers to its derived classes.** Inheritance works one way: the child uses the parent.
- **Avoid bidirectional dependencies.** If A needs B and B needs A, neither works until the other does, and
  you end up with half-initialised objects or null references. Keep references shaped like a tree.
- **A class has both state and behaviour.** Data plus methods that act on it. A class with only one of the
  two can usually be expressed more simply. Exceptions exist, such as data transfer objects (state only).
- **A class protects the consistency of its own state.** Validate values in setters and constructors so no
  caller can put the object into an invalid or crashing state.

## Member design

- **Properties can be set in any order.** Members do not depend on each other being set first. Handle real
  dependencies in the constructor or one initialisation method.
- **A property, method or local function does one thing,** and its name says what that is. No hidden side
  effects beyond what the name implies.
- **Strings and collections are never null.** Properties, arguments and return values that represent a string
  or collection are empty (`string.Empty`, `[]`, `Array.Empty<T>()`) rather than `null`.

## Naming

- Do not prefix fields, except with an underscore for private fields (`_count`, not `m_count` or `strName`).
- Do not repeat the class name in its members (`Customer.Name`, not `Customer.CustomerName`).
- Avoid short names or names that are easily confused with others (`index`, not `i` outside a short loop;
  not `l` next to `1`).
- Name types with nouns, noun phrases or adjective phrases (`OrderRepository`, `IComparable`).
- Give generic type parameters descriptive names prefixed with `T` (`TEntity`, `TResult`), unless a single
  `T` is self-explanatory.
- Name methods and local functions with verbs or verb-object pairs (`Calculate`, `SendInvoice`).
- Name events with verbs or verb phrases (`Closing`, `Closed`, `PriceChanged`).
- Postfix asynchronous methods with `Async` (or `TaskAsync` when an `Async` name already exists).
- Test methods follow separate naming guidelines that this skill does not cover.

## Maintainability

- **A method has at most 7 statements.** More means it does more than one thing: extract methods.
- **Members are `private` and types `internal sealed` by default.** Widen only when something needs it.
- **No magic numbers.** Use a named constant or enum (`MaxRetries`, not `3`). Obvious values such as `0`
  and `1` in a loop are fine.
- **Use `var` only when the type is obvious** from the right-hand side (`var orders = new List<Order>();`).
  Write the type when it comes from a method call whose name does not reveal it.
- **One variable per statement.** No `int a = 1, b = 2;`.
- **Prefer object and collection initializers** over separate assignment statements.
- **Every `switch` ends with a `default` case,** even if it only throws for an unexpected value.
- **Wrap complex expressions** in a well-named property, method or local function instead of inline
  conditions.
- **Do not comment out code.** Delete it; version control remembers.

```csharp
// Avoid
if (order.Lines.Count > 0 && order.Customer != null && !order.Customer.IsBlocked && order.Total < 10000) { }

// Prefer
private const decimal MaxOrderTotal = 10_000m;

private bool CanBeShipped(Order order) =>
    order.Lines.Count > 0 && order.Customer is { IsBlocked: false } && order.Total < MaxOrderTotal;
```

## Exceptions, events and LINQ

- **Do not swallow errors by catching generic exceptions.** Catch the specific exceptions you can handle;
  let the rest propagate. `catch (Exception)` only at a top-level boundary that logs and rethrows or reports.
- **Check an event's delegate for null before raising it:** `PriceChanged?.Invoke(this, args);`.
- **Never pass `null` as the sender** when raising an event; pass `this` (or the real source).
- **Evaluate a LINQ query before returning it** (`ToList()`, `ToArray()`) so callers do not re-run a lazy
  query or hit a disposed context.
- **Do not use `this.` or `base.` prefixes** unless they are required to disambiguate.

## Performance

- **Use `async`/`await` for long-running work that is mostly waiting** (I/O, network, database).
- **Use `Task.Run` for CPU-intensive work,** so it does not block the calling thread.
- **Do not mix `await` with `Task.Wait()` or `.Result`.** Blocking on a task inside async code causes
  deadlocks and thread-pool starvation: await all the way.

## Framework usage

- **Use C# type aliases** instead of `System` types (`int`, `string`, `bool`, not `Int32`, `String`, `Boolean`).
- **Prefer language syntax over explicit calls** to the underlying implementation (`x?.Length`, `x ?? y`,
  `items is []`, `nameof(x)`, rather than hand-written null checks or string literals).

## Comments and documentation

- **Write comments and documentation in English.**
- **Comment only to explain a complex algorithm or a decision** (the why), not what the code already says.

## Layout

- **Use a common layout:** the team `.editorconfig` and the IDE formatter decide; do not hand-format.
- **Place members in a fixed order:** constants and fields, constructors, properties, events, public methods,
  then non-public methods. Keep related members together.
- **Be reluctant with `#region` / `#endregion`.** A class that needs regions to be readable usually does too
  much; split it instead.

## Enforcing with .editorconfig

When asked to enforce the guidelines, propose `.editorconfig` rules for what an analyzer can check: `var`
usage (`csharp_style_var_*`), type aliases (`dotnet_style_predefined_type_for_*`), no `this.`
(`dotnet_style_qualification_for_*`), private field naming with `_` (`dotnet_naming_rule`), object and
collection initializers (`dotnet_style_object_initializer`, `dotnet_style_collection_initializer`) and
`switch` default handling. Rules such as single purpose, 7 statements and English comments stay a code
review matter.
