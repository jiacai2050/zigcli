---
name: zig-tiger-style
description: >
  TigerStyle Zig coding guidelines — distilled from TigerBeetle's production codebase. Use this
  skill whenever the user is writing, reviewing, or refactoring Zig code, asking about Zig
  idioms, best practices, assertions, memory layout, naming conventions, or code style. Also
  trigger when the user asks how to structure Zig structs, handle errors, write safe loops, or
  design Zig APIs. Even if the user just says "write me some Zig" or pastes Zig code for review,
  consult this skill first.
---

# TigerStyle: Zig Coding Guidelines

Distilled from TigerBeetle's [TIGER_STYLE.md](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
Design goal priority: **Safety > Performance > Developer Experience**.

---

## 1. Safety

### Control Flow
- Use only **simple, explicit control flow**. No recursion unless provably bounded.
- Split compound conditions into nested `if/else` branches — ensure both the positive and negative
  spaces are handled or asserted.
- State invariants positively:

  ```zig
  // preferred
  if (index < length) { ... } else { ... }

  // avoid
  if (index >= length) { ... }
  ```

- Every `if` branch should prompt the question: does a corresponding `else` also need to be handled?

### Assertions
Assertions detect **programmer errors** — not expected runtime errors. The only correct response
to corrupt state is to crash. Assertions downgrade catastrophic correctness bugs into liveness bugs.

- A function must not operate blindly on data it has not checked; assert arguments at the entry point.
- **Pair assertions**: for any property you want to enforce, add assertions on at least two different
  code paths (e.g. just before writing to disk, and immediately after reading back).
- Split compound assertions:

  ```zig
  // preferred
  assert(a);
  assert(b);

  // avoid
  assert(a and b);
  ```

- Use a single-line `if` to assert an implication: `if (a) assert(b);`
- **Assert relationships between compile-time constants** to verify design integrity before the
  program even runs:

  ```zig
  comptime assert(@sizeOf(Header) == 128);
  comptime assert(config.pipeline_max <= config.batch_max);
  ```

- Assert both the **positive space** (what you expect to be true) and the **negative space** (what
  you expect to be false) — the boundary between valid and invalid is where bugs hide.

### Memory
- Initialize large structs **in-place via an out pointer** to eliminate intermediate copies and
  guarantee pointer stability:

  ```zig
  // preferred
  fn init(target: *LargeStruct) !void {
      target.* = .{ ... };
  }

  // avoid
  fn init() !LargeStruct {
      return LargeStruct{ ... };
  }
  ```

### Variable Scope
- Declare variables at the **smallest possible scope** to reduce the chance of misuse.
- Declare variables **close to where they are used** — do not introduce them before they are needed.
  This avoids POCPOU bugs (a distant cousin of TOCTOU).

### Loops and Queues
- All loops and queues must have a **fixed upper bound** to prevent infinite loops or tail-latency
  spikes. Follow the fail-fast principle.
- Loops that genuinely cannot terminate (e.g. an event loop) must be explicitly asserted as such.

### Error Handling
- **All errors must be handled.** Most catastrophic production failures stem from incorrect handling
  of non-fatal errors.
- Never discard error return values with `_`.

### Other
- Use **explicitly-sized integer types** (`u32`, `i64`, etc.), avoid architecture-dependent `usize` when possible
- Enable and respect the **compiler's strictest warning settings** — zero tolerance for warnings.
- Do not react directly to external events inline; let the program run at its own pace (enables
  batching and maintains control-flow ownership).
- **Keep functions as small as possible.** When splitting, find semantically clean cut points:
  - Centralize all `if`/`switch` in the "parent" function; extract pure logic into helpers.
  - Let the parent own all mutable state; helpers compute what to change but don't apply it.
  - Rule of thumb: ["push `if`s up and `for`s down"](https://matklad.github.io/2023/11/15/push-ifs-up-and-fors-down.html).

---

## 2. Performance

- Solve performance in the **design phase** — the biggest wins (1000x) come from architecture,
  not post-hoc profiling.
- Do **back-of-the-envelope sketches** across the four resources (network, disk, memory, CPU) and
  their two characteristics (bandwidth, latency).
- Optimize slowest resources first: network → disk → memory → CPU, weighted by access frequency.
- **Batching** is the primary tool: amortize network, disk, memory, and CPU costs.
- Distinguish **control plane** from **data plane**; batching lets both coexist safely and fast.
- Extract hot-path loops into **standalone functions with primitive arguments** (no `self`) so the
  compiler can cache fields in registers and humans can spot redundant work:

  ```zig
  // hot loop extracted, no self
  fn process_batch(items: []const Item, result: []Output) void { ... }
  ```

- Be explicit. Do not rely on the compiler to do the right thing.
- **Always pass options explicitly** at library call sites — never rely on defaults:

  ```zig
  // preferred
  @prefetch(a, .{ .cache = .data, .rw = .read, .locality = 3 });

  // avoid
  @prefetch(a, .{});
  ```

---

## 3. Naming

- In general, functions are `camelCase`, types are `PascalCase`, variables are `lowercase_with_underscores`.
  One exception to those rules is functions that return types. They are `PascalCase`:
  ```zig
  pub fn ArrayList(comptime T: type) type {
    return ArrayListAligned(T, null);
  }
  ```
- Normally, file names are `lowercase_with_underscore`. However, files that expose a type directly should be `PascalCase`.
- **Do not abbreviate variable names** (except primitive integer loop indices in sorts/matrices).
- Acronyms are fully capitalized: `VSRState`, not `VsrState`.
- **Append units and qualifiers to names**, ordered by descending significance, so the most
  important word comes first:

  ```zig
  latency_ms_max    // not max_latency_ms
  latency_ms_min    // aligns nicely with the above
  message_size_max
  ```

- Choose related names with the **same character count** so they align visually:

  ```zig
  source         // same length as target
  target
  source_offset
  target_offset
  ```

- Name helper/callback functions with the caller's name as a prefix:
  `read_sector()` → `read_sector_callback()`
- **Callbacks go last** in the parameter list (mirrors invocation order).
- Infuse names with meaning: `gpa: Allocator` and `arena: Allocator` are far more informative
  than `allocator: Allocator`.
- Functions that take two `u64` arguments must use a named `options: struct` parameter to prevent argument confusion.

### Struct and File Layout

```zig
// Struct order: fields → type definitions → methods
time: Time,
process_id: ProcessID,

const ProcessID = struct { cluster: u128, replica: u8 };
const Tracer = @This();

pub fn init(gpa: std.mem.Allocator, time: Time) !Tracer { ... }
```

- The `main` function goes at the top of the file — readers see the most important thing first.
- Promote complex nested types to top-level structs.

---

## 4. Comments

- Comments are full sentences: space after `//`, capital letter, ending with a period (or colon
  when introducing something). Inline end-of-line comments may be phrases without punctuation.
- **Always say why.** Code shows what and how; comments explain the reasoning behind decisions.
- Add a description at the top of tests explaining the goal and methodology.
- On occasion, use an obviously-true assertion *instead of* a comment to document a critical,
  surprising invariant — the assertion is stronger documentation.

---

## 5. Formatting

- Always run `zig fmt`.
- Use **4 spaces** of indentation (more visually obvious than 2 at a distance).
- **Hard limit of 100 columns per line**, no exceptions. Add a trailing comma and let `zig fmt`
  handle the wrapping.
- **Always add braces to `if` statements** unless the whole thing fits on one line:

  ```zig
  // single-line ok without braces
  if (ok) return;

  // multi-line always needs braces
  if (condition) {
      do_something();
  }
  ```

### Division — be explicit about rounding intent

```zig
@divExact(a, b)   // asserts no remainder
@divFloor(a, b)   // rounds toward negative infinity
div_ceil(a, b)    // rounds toward positive infinity
```

---

## 6. Off-by-One Errors

`index` (0-based), `count` (1-based), and `size` (= count × unit) are **distinct types** with
clear conversion rules:

- `index` → `count`: add 1
- `count` → `size`: multiply by the unit size
- Include units and qualifiers in variable names (see Naming) to make these conversions visible.

---

## 7. Dependencies and Tooling

- **Zero-dependencies policy**: no external dependencies beyond the Zig toolchain.
- Write scripts as `scripts/*.zig` instead of `*.sh` — cross-platform, type-safe, more reliable.
- Standardize on Zig for tooling to reduce dimensionality as the team grows.

---

## Pre-Commit Checklist

Before submitting, verify:

- [ ] All lines are <= 100 columns; `zig fmt` has been run
- [ ] All errors are handled (no `_` discards)
- [ ] Variable names include units/qualifiers and are not abbreviated
- [ ] Compound conditions are split into nested `if/else`
- [ ] All loops have an explicit upper bound
- [ ] Comments explain *why*, not just *what*
- [ ] Compile-time constant relationships are verified with `comptime assert`
