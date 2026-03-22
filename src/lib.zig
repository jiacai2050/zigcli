//! zigcli is a toolkit for building command-line programs in Zig.
//!
//! The root module bundles the repository's reusable Zig packages behind one import root.
//! Import `zigcli` once, then access the individual packages as
//! `zigcli.pretty_table`, `zigcli.structargs`, `zigcli.gitignore`, and `zigcli.term`.

const std = @import("std");

/// The table rendering package.
pub const pretty_table = @import("pretty-table.zig");

/// The struct-driven command-line argument parsing package.
pub const structargs = @import("structargs.zig");

/// The `.gitignore` pattern matching package.
pub const gitignore = @import("gitignore.zig");

/// Shared terminal helpers and ANSI color definitions.
pub const term = @import("term.zig");

test {
    std.testing.refAllDecls(@This());
}
