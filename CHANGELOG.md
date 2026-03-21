# Changelog

## Unreleased

### Breaking Changes
- **build**: package consumers must now import the single `zigcli` root module instead of adding
  separate `simargs`, `pretty-table`, and `gitignore` modules, and the struct-based argument parser
  is now named `structargs`
  - Old:
    - `exe.root_module.addImport("simargs", zigcli.module("simargs"));`
    - `exe.root_module.addImport("pretty-table", zigcli.module("pretty-table"));`
    - `exe.root_module.addImport("gitignore", zigcli.module("gitignore"));`
  - New:
    - `exe.root_module.addImport("zigcli", zigcli.module("zigcli"));`
    - Use `zigcli.structargs` instead of `zigcli.simargs`

### New Programs
- **pretty-csv**: Pretty-print CSV/TSV files as aligned tables
  - Auto-fits table width to terminal, truncates with `…`
  - Three border styles: `ascii`, `box`, `dos`
  - Transpose mode (`-t`): show each record as vertical key-value block
  - Column selection (`-c 1,3,5`): display only specific columns
  - Row separators (`--row-separator`) and right-aligned selected columns (`-r 2,4`)
  - Configurable delimiter, padding, and max input size

### Improvements
- **build**: consolidate exported packages behind a single `zigcli` root module in `lib.zig`
- **zigcli**: add shared `term` module for ANSI colors and terminal capability helpers
- **zigcli**: add shared `term.Style` for reusable ANSI-styled text output
- **zigcli**: add `term.stdoutWidth()` as a convenience wrapper for stdout terminal-width detection
- **structargs**: `print_help_on_error` now prints the subcommand-specific help context for subcommand parse failures
- **pretty-table**: `Table(N).Owned` runtime row helper with string shorthand and Cell-level control
  - `Table(N)` and `Table(N).Owned`: optional transpose mode
  - `RuntimeTable`: runtime column count with footer rows, header/footer cell setters, row separators, per-column alignment, `"{f}"` formatting, optional cell truncation, and UTF-8-safe truncation boundaries
  - Windows targets skip POSIX terminal-width probing during cross-compilation

### Documentation
- Added `gitignore` package docs
- Added `term` package docs
- Updated `pretty-table` and `structargs` docs for Zig 0.15 API

## v0.4.0 (2026-03-18)

### New Programs
- **zfetch**: System information fetcher (renamed from `fastfetch`), inspired by [fastfetch](https://github.com/fastfetch-cli/fastfetch)
  - Cross-platform: macOS, Linux, and FreeBSD
  - OS-specific ASCII art logos with multi-color support (Apple rainbow, Tux, FreeBSD daemon)
  - `--format json` for machine-readable output (streamed, no intermediate allocation)
  - `--all` flag for slow operations (package count, shell version)
  - Automatic color detection: no ANSI codes when output is redirected
  - Detailed memory breakdown (App/Wired/Compressed on macOS, Swap on Linux)
  - Human-friendly sizes (auto GiB/MiB)
  - Platform-modular architecture: `common.zig` + per-OS modules with comptime dispatch
- **progress**: Port of [progress](https://github.com/Xfennec/progress) (Linux + macOS)
- **cowsay**: ASCII cow message display

### New Modules
- **gitignore**: Pure Zig glob matching (removed libc `fnmatch` dependency)
  - Recursive `.gitignore` filtering support in `tree` and `loc`

### Improvements
- **build**: consolidate exported packages behind a single `zigcli` root module in `lib.zig`
- **pretty-table**: `Cell` struct with per-cell styling and horizontal span
- **simargs**: Improved naming consistency for internal types
- **zigfetch**: Increased zstd decompression buffer size

### Bug Fixes
- Fixed slash handling in gitignore rules
- Fixed integer overflow for blank line counting in `loc`
- Fixed Linux `struct_statvfs` bitfield issue (manual extern struct for cross-compilation)

### Other
- Added project logo
- Upgraded to Zig 0.15.x
