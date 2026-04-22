# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zigcli is a toolkit for building command-line programs in Zig (currently targeting Zig 0.16.0). It provides both reusable Zig packages (modules) and standalone CLI programs.

## Build Commands

```bash
zig build                          # Debug build
zig build test --summary all       # Run all tests
zig build test-zigcli --summary all  # Run all reusable module tests via the root module
zig build test-<name> --summary all  # Run tests for a single binary/helper (e.g., test-loc, test-util)
zig fmt --check .                  # Check formatting
zig build run-<name> -- <args>     # Run a specific binary (e.g., run-tree, run-loc)
make build                         # Release build with version/date/commit metadata
make ci                            # fmt + test (what CI runs)
```

## Architecture

### Modules (`src/`)

Reusable Zig packages exported via `build.zig` and bundled under a single `zigcli` root module (`src/lib.zig`):

- **structargs** — Struct-based CLI argument parser
- **pretty-table** — Terminal table renderer with ASCII/box/DOS border styles
- **gitignore** — Pure Zig `.gitignore` glob matching
- **csv** — RFC 4180 delimited text parser
- **term** — ANSI colors and terminal capability helpers
- **progress** — Terminal progress bars and spinners

### Binaries (`src/bin/`)

Each `.zig` file in `src/bin/` is a standalone CLI tool. The build system auto-wires them with `run-<name>` and `install-<name>` steps. Key binaries:

- **loc** — Lines-of-code counter (multi-language)
- **tree** — Directory tree viewer
- **pretty-csv** — Pretty-print CSV/TSV files as aligned tables
- **zfetch** — System information fetcher (macOS, Linux, FreeBSD)
- **zigfetch** — URL fetcher (depends on zig-curl)
- **tcp-proxy** — TCP proxy server (Linux zero-copy via splice)
- **progress-it** — Port of [progress](https://github.com/Xfennec/progress) (Linux + macOS)
- **cowsay** — ASCII cow message display
- **repeat** — Repeat a command
- **night-shift** / **dark-mode** — macOS-only (link private frameworks; skipped on non-macOS)
- **pidof** — macOS-only process lookup
- **timeout** — Skipped on Windows (no sigaction)

Shared utilities live in `src/bin/util.zig` (build info, string helpers). All binaries import `structargs` and most import `pretty-table` from the modules.

### Build System (`build.zig`)

The build file uses `comptime inline for` to register all binaries and modules. For each binary it creates:
- `zig build run-<name>` — run step
- `zig build install-<name>` — install step
- `zig build test-<name>` — test step for binaries/helpers

Reusable modules are covered by `zig build test-zigcli`, which exercises the unified root module.

Platform-specific binaries return `null` from `makeCompileStep` when the target OS doesn't match, so they are silently skipped.

Build metadata (version, git commit, build date) is injected via `build_info` options module.

### Examples (`examples/`)

Demo programs (`structargs-demo`, `pretty-table-demo`) that exercise the modules.

### Dependencies

Single external dependency: **zig-curl** (used only by zigfetch, lazy-loaded).
