const std = @import("std");

const Table = @import("pretty-table").Table;
const Separator = @import("pretty-table").Separator;
const Cell = @import("pretty-table").Cell;
const Align = @import("pretty-table").Align;
const Color = @import("pretty-table").Color;

pub fn main() !void {
    const out = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = out.writer(&buf);

    // Basic table with box-drawing borders
    const basic = Table(2){
        .header = [_]Cell{ Cell.init("Language"), Cell.init("Files") },
        .rows = &[_][2]Cell{
            .{ Cell.init("Zig"), Cell.init("3") },
            .{ Cell.init("Python"), Cell.init("2") },
            .{ Cell.init("C"), Cell.init("12") },
            .{ Cell.init("Ruby"), Cell.init("5") },
        },
        .footer = [2]Cell{ Cell.init("Total"), Cell.init("22") },
        .mode = .box,
        .padding = 1,
    };
    try writer.interface.print("=== Box mode with padding ===\n{f}\n", .{basic});

    // Right-align numeric columns
    const scores = Table(3){
        .header = [_]Cell{ Cell.init("Name"), Cell.init("Score"), Cell.init("Rank") },
        .rows = &[_][3]Cell{
            .{ Cell.init("Alice"), Cell.init("9800"), Cell.init("1") },
            .{ Cell.init("Bob"), Cell.init("7500"), Cell.init("2") },
            .{ Cell.init("Charlie"), Cell.init("5100"), Cell.init("3") },
        },
        .mode = .box,
        .padding = 1,
        .column_align = .{ .left, .right, .right },
    };
    try writer.interface.print("=== Right-aligned numeric columns ===\n{f}\n", .{scores});

    // Center-aligned headers
    const centered = Table(3){
        .header = [_]Cell{ Cell.init("CPU"), Cell.init("Memory"), Cell.init("Disk") },
        .rows = &[_][3]Cell{
            .{ Cell.init("45%"), Cell.init("62%"), Cell.init("30%") },
            .{ Cell.init("80%"), Cell.init("71%"), Cell.init("55%") },
        },
        .mode = .dos,
        .padding = 1,
        .column_align = .{ .center, .center, .center },
    };
    try writer.interface.print("=== Center-aligned (DOS mode) ===\n{f}\n", .{centered});

    // Row separators between every data row
    const with_seps = Table(2){
        .header = [_]Cell{ Cell.init("Step"), Cell.init("Status") },
        .rows = &[_][2]Cell{
            .{ Cell.init("Build"), Cell.init("OK") },
            .{ Cell.init("Test"), Cell.init("OK") },
            .{ Cell.init("Deploy"), Cell.init("PENDING") },
        },
        .padding = 1,
        .row_separator = true,
    };
    try writer.interface.print("=== Row separators ===\n{f}\n", .{with_seps});

    // Per-cell styling: foreground colors, bold, italic, background color
    const styled = Table(3){
        .header = [_]Cell{
            Cell.init("Service").withFg(.bright_white).withBold(),
            Cell.init("Status").withFg(.bright_white).withBold(),
            Cell.init("Uptime").withFg(.bright_white).withBold(),
        },
        .rows = &[_][3]Cell{
            .{ Cell.init("web"), Cell.init("UP").withFg(.green), Cell.init("99.9%").withFg(.green) },
            .{ Cell.init("db"), Cell.init("UP").withFg(.green), Cell.init("99.5%").withFg(.green) },
            .{ Cell.init("cache"), Cell.init("DOWN").withFg(.red).withBold(), Cell.init("0.0%").withFg(.red) },
        },
        .footer = [3]Cell{
            Cell.init("Summary").withFg(.yellow),
            Cell.init("2/3 UP").withFg(.yellow),
            Cell.init("").withFg(.yellow),
        },
        .mode = .box,
        .padding = 1,
    };
    try writer.interface.print("=== Per-cell styling ===\n{f}\n", .{styled});

    // Column spanning (hspan): one cell spans multiple columns
    const spanned = Table(4){
        .header = [_]Cell{
            Cell.init("Name"),
            Cell.init("Q1"),
            Cell.init("Q2"),
            Cell.init("Q3"),
        },
        .rows = &[_][4]Cell{
            .{ Cell.init("Alice"), Cell.init("90"), Cell.init("85"), Cell.init("92") },
            // "N/A" spans columns 1-3 (Q1, Q2, Q3)
            .{ Cell.init("Bob"), Cell.init("N/A (on leave)").withHspan(3), Cell.span(), Cell.span() },
        },
        .padding = 1,
        .mode = .box,
    };
    try writer.interface.print("=== Column spanning (hspan) ===\n{f}\n", .{spanned});

    try writer.interface.flush();
}
