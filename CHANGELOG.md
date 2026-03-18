# Changelog

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
