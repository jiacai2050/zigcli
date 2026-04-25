# zhexdump Design

**Date:** 2026-04-25  
**Status:** Approved

## Overview

`zhexdump` is a color-coded hex dump tool inspired by [simonomi.dev/blog/color-code-your-bytes](https://simonomi.dev/blog/color-code-your-bytes). It uses a hybrid semantic+gradient color scheme to make byte patterns visually recognizable — combining the meaning of semantic categories (null, whitespace, ASCII, control, high bytes) with brightness gradients within each category to reveal finer structure.

## Architecture

A standalone binary at `src/bin/zhexdump.zig`, auto-wired by the existing build system alongside other binaries. No new module — all logic lives in the binary file.

Dependencies:
- `structargs` — CLI argument parsing
- `term.zig` — ANSI color output

Core loop: read up to 16 bytes at a time → format offset → print each hex byte with color → pad short final line → print ASCII panel. Single pass, no buffering beyond one row.

## CLI Interface

```
zhexdump [options] [file]

Options:
  -n, --length <N>    Only read N bytes
  -s, --skip <N>      Skip N bytes from the start
  -C, --no-color      Disable color output
  --help              Show help

Arguments:
  file                File to read (default: stdin)
```

Output format (16 bytes/line):

```
00000000  48 65 6c 6c  6f 2c 20 57  6f 72 6c 64  21 0a 00 ff  |Hello, World!...|
```

- Offset: 8 zero-padded hex digits
- Bytes grouped as 4+4+4+4 with a double-space between the two halves of 8
- ASCII panel enclosed in `|...|`
- Each byte and its ASCII panel character share the same color

## Color Scheme

7 visual states, all mapped to existing `term.zig` colors:

| Byte Range | Category | Color |
|---|---|---|
| `00` | Null | `bright_black` |
| `01`-`08`, `0B`, `0C`, `0E`-`1F`, `7F` | Control chars | `red` |
| `09`, `0A`, `0D`, `20` | Whitespace | `yellow` |
| `21`-`4F` | Printable ASCII (low) | `green` |
| `50`-`7E` | Printable ASCII (high) | `bright_green` |
| `80`-`BF` | High bytes (low) | `blue` |
| `C0`-`EF` | High bytes (mid) | `bright_blue` |
| `F0`-`FE` | High bytes (high) | `magenta` |
| `FF` | Max byte | `bright_white` |

Offset column: `bright_black` for the `0x` prefix, `white` for the hex digits.

Color is auto-disabled when stdout is not a TTY (`std.posix.isatty`). `--no-color` forces it off regardless.

## Error Handling

- File not found or unreadable: error to stderr, exit 1
- Empty input: no output, exit 0
- `-s` skip ≥ file size: no output, exit 0
- `-n 0`: no output, exit 0
- Non-TTY stdout: color disabled automatically
