---
title: Roadmap
type: docs
weight: 30
---

`zigcli` already has two complementary kinds of value:

- as a set of reusable Zig packages for building CLI tools
- as a collection of standalone command-line programs that users can install directly

The next phase should prioritize foundational capabilities that can be reused across both sides of the project, instead of only adding more isolated utilities.

## P0: Strengthen the CLI foundation

### 1. Configuration system

Goal: provide a unified configuration layer that merges command-line flags, environment variables, and config files.

Suggested capabilities:

- a standard `--config <path>` convention
- environment variable prefix mapping
- clear precedence across defaults, config file values, environment variables, and CLI flags
- `TOML` support first, with room to add `JSON` and `YAML` later

Why it matters:

- almost every medium-sized or large CLI eventually needs this
- it would directly benefit tools like `zigfetch`, `tcp-proxy`, and future network- or service-oriented programs
- it would pair naturally with `structargs` and make the overall CLI experience much more complete

### 2. `structargs` enhancements

Goal: evolve `structargs` from a capable argument parser into a more complete CLI framework foundation.

Suggested capabilities:

- stronger subcommand tree support
- mutual exclusion, dependency, and required-group validation
- visibility into where defaults come from (`default`, `env`, `config`)
- shell completion generation
- richer help output layouts

Why it matters:

- this is one of the highest-leverage reusable modules in the repository
- improving it once benefits every CLI in the project
- it would make `zigcli` more attractive as a dependency for external users

### 3. Terminal interaction primitives

Goal: add the common interactive building blocks used by modern CLIs.

Suggested capabilities:

- `confirm`
- `prompt`
- `select`
- ~~`spinner`~~ ✅ implemented in `progress` package
- ~~`progress`~~ ✅ implemented in `progress` package

Why it matters:

- the repository already has table rendering, terminal styling, and progress-related tools, so this is a natural extension
- it would allow `zigcli` to support richer terminal product experiences instead of only text output

## P1: Extract reusable output and filesystem capabilities

### 4. Unified output interface

Goal: make commands work well for both humans and automation.

Suggested capabilities:

- a common output model for `table / json / csv / tsv / plain`
- shared output switching interfaces
- consistent conventions for normal output and error output

Why it matters:

- `pretty-table` already serves human-readable output well, but scripting support can be stronger
- this would make many commands naturally easier to integrate into automation workflows

### 5. Shared file traversal and filtering module

Goal: turn logic currently spread across `tree`, `loc`, and `.gitignore` handling into a reusable foundation.

Suggested capabilities:

- recursive traversal
- include / exclude rules
- `.gitignore` integration
- depth limits
- file type filtering
- reusable callback-based statistics or processing hooks

Why it matters:

- `tree` and `loc` already show that these patterns repeat
- extracting them would make future tools like `find`, `du`, and batch-processing utilities much easier to build

### 6. Terminal compatibility and rendering improvements

Goal: make terminal output more robust across environments.

Suggested capabilities:

- unified TTY detection
- automatic color fallback
- Unicode / ASCII fallback
- shared terminal width and truncation strategies

Why it matters:

- existing tools like `pretty-table`, `tree`, and any styled output would all benefit
- it would reduce display issues across shells, CI, and remote environments

## P2: Expand the networking and system-tool direction

### 7. Lightweight HTTP client capability

Goal: extract reusable networking functionality from `zigfetch`.

Suggested capabilities:

- basic GET / POST support
- timeouts
- retries
- headers
- simple download support

Why it matters:

- this would turn `zigfetch` from a single tool into a platform capability
- future API debugging, downloader, and webhook-related tools would become much easier to implement

### 8. Stronger system information and process tooling

Goal: deepen the direction already represented by `zfetch`, `hexdump`, `progress`, and `pidof`.

Suggested directions:

- richer process inspection
- system resource statistics
- a more stable cross-platform abstraction layer
- better behavior alignment across Linux, macOS, and FreeBSD

Why it matters:

- these tools fit the identity of `zigcli` very naturally
- they also help validate whether the lower-level modules are designed broadly enough

## P3: Improve packaging and developer experience

### 9. Documentation and examples

Goal: make it easier for external developers to adopt `zigcli` as a dependency.

Suggested work:

- add a minimal runnable example for each core module
- expand the README with scenario-based entry points
- make the mapping between `examples/` and `docs/` more explicit

### 10. Installation and distribution experience

Goal: make the project feel more polished and ready to use immediately.

Suggested directions:

- shell completion installation guidance
- man page generation
- clearer release artifact naming and distribution guidance

## Recommended implementation order

1. Configuration system
2. `structargs` enhancements
3. Terminal interaction primitives
4. Unified output interface
5. Shared file traversal and filtering module
6. Terminal compatibility and rendering improvements
7. Lightweight HTTP client capability
8. Stronger system information and process tooling
9. Documentation and examples
10. Installation and distribution experience

## A focused near-term strategy

If only one theme should be prioritized next, the best choice is:

**build a strong combination of `structargs + config + completion`.**

Why:

- it is the most platform-like investment
- it would benefit almost every existing command directly
- it strengthens both sides of the repository: the reusable library side and the standalone tools side
- it would make external developers more likely to adopt `zigcli` as their CLI foundation
