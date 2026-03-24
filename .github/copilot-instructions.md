# zigcli Copilot Instructions

## Build, test, and formatting commands

- `zig build` builds all supported binaries and examples for the current host/target.
- `make build` performs a release build and injects build metadata (`version`, `git_commit`, `build_date`).
- `zig fmt --check .` checks formatting.
- `zig fmt .` fixes formatting.
- `zig build test --summary all` runs the full test suite.
- `zig build test-zigcli --summary all` runs tests for the reusable root module exported from `src/lib.zig`.
- `zig build test-<name> --summary all` runs one binary/helper test target, for example `zig build test-loc --summary all`, `zig build test-tree --summary all`, or `zig build test-util --summary all`.
- `make ci` runs the same repo-level checks used by CI: formatting plus tests.
- `zig build docs` generates Zig API docs into `zig-out/docs`.
- `zig build run-<name> -- <args>` runs a specific CLI during development.

## High-level architecture

- This repository combines two things in one codebase: reusable Zig packages and standalone CLI programs.
- The reusable import surface is the single root module `zigcli`, defined in `src/lib.zig`. It currently re-exports `structargs`, `pretty_table`, `gitignore`, `term`, `csv`, and `progress`.
- The build is centralized in `build.zig`. It registers the `zigcli` root module once, injects a private `build_info` module, then uses comptime loops to auto-register binaries and examples.
- Every standalone program in `src/bin/*.zig` gets matching `run-<name>`, `install-<name>`, and `test-<name>` build steps automatically.
- Tests are mostly co-located inside the source files with Zig `test` blocks. `test-zigcli` exercises the reusable module root; per-binary tests come from the individual source files.
- `src/bin/util.zig` is the shared helper layer for binaries. It provides allocator setup, build metadata formatting, string helpers, verbose logging, and a few small platform helpers.
- The binaries are also the best real examples of how the reusable packages fit together. For example, `src/bin/loc.zig`, `src/bin/tree.zig`, and `src/bin/pretty-csv.zig` show typical integration of `structargs`, `pretty_table`, `gitignore`, and shared utilities.
- `examples/` contains smaller demo programs for the packages, while `docs/` is a Hugo site for project documentation.
- Platform support is intentionally enforced in `build.zig`, not ad hoc in each command. Some binaries are skipped entirely when the host/target OS is unsupported:
  - `pidof`, `night-shift`, and `dark-mode` are macOS-only.
  - `timeout` is skipped on Windows.
  - `progress-it` only builds on macOS and Linux.
  - `zfetch` has OS-specific behavior and linking.
  - `zigfetch` depends on the external `zig-curl` package from `build.zig.zon`.

## Key codebase conventions

- Target the current toolchain declared by the repo, not older assistant docs. `build.zig.zon` currently requires Zig `0.15.2`.
- When changing package exports, update `src/lib.zig` and keep the root import pattern as `const zigcli = @import("zigcli");`.
- New CLI binaries should follow the existing pattern:
  - import `zigcli` plus `src/bin/util.zig`
  - define an options struct for `structargs`
  - populate `__shorts__` and `__messages__` for help text
  - pass `version_string = util.get_build_info()` into `structargs.parse`
- Shared binary behavior belongs in `src/bin/util.zig` rather than being copied between commands.
- Allocator handling follows existing Zig 0.15 patterns:
  - binaries commonly start from `var gpa = util.Allocator.instance; defer gpa.deinit();`
  - temporary per-operation data often uses `std.heap.ArenaAllocator`
  - `std.ArrayList` is used in unmanaged style (`.empty`, then pass the allocator to `append`, `appendSlice`, and `deinit`)
- I/O follows the newer Zig 0.15 writer API. Representative binaries create a buffered writer with `stdout.writer(&buf)` and pass `&writer.interface` to helpers that accept `*std.Io.Writer`.
- Many CLIs honor `.gitignore` filtering through `zigcli.gitignore.GitignoreStack`; preserve that behavior unless the command explicitly opts out with a `no-gitignore` flag.
- Tests live beside the implementation. Prefer adding `test` blocks to the relevant module or binary source file instead of creating separate test harnesses unless the existing structure already does so.
- Build-time platform gating belongs in `build.zig` via `sourceSupported()` and `configureCompileStep()`. If a new binary needs frameworks, libc, or OS restrictions, wire it there so the generated build steps stay accurate.
- Release metadata is compile-time data supplied by the private `build_info` module. Reuse `util.get_build_info()` instead of inventing per-command version output.

## Existing project guidance worth keeping aligned with

- `README.org` explains the dual package-plus-program structure and is the best high-level product overview.
- `CLAUDE.md` and `GEMINI.md` already document common build/test flows and project shape, but some older wording about module layout is stale. Prefer the current structure in `src/lib.zig` and `src/*.zig`.
