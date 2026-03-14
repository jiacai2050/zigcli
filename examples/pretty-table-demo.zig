const std = @import("std");

const Table = @import("pretty-table").Table;
const Separator = @import("pretty-table").Separator;
const String = @import("pretty-table").String;
const Align = @import("pretty-table").Align;
const Color = @import("pretty-table").Color;

pub fn main() !void {
    const out = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = out.writer(&buf);

    // Basic table with box-drawing borders
    const basic = Table(2){
        .header = [_]String{ "Language", "Files" },
        .rows = &[_][2]String{
            .{ "Zig", "3" },
            .{ "Python", "2" },
            .{ "C", "12" },
            .{ "Ruby", "5" },
        },
        .footer = [2]String{ "Total", "22" },
        .mode = .box,
        .padding = 1,
    };
    try writer.interface.print("=== Box mode with padding ===\n{f}\n", .{basic});

    // Right-align numeric columns
    const scores = Table(3){
        .header = [_]String{ "Name", "Score", "Rank" },
        .rows = &[_][3]String{
            .{ "Alice", "9800", "1" },
            .{ "Bob", "7500", "2" },
            .{ "Charlie", "5100", "3" },
        },
        .mode = .box,
        .padding = 1,
        .column_align = .{ .left, .right, .right },
    };
    try writer.interface.print("=== Right-aligned numeric columns ===\n{f}\n", .{scores});

    // Center-aligned headers
    const centered = Table(3){
        .header = [_]String{ "CPU", "Memory", "Disk" },
        .rows = &[_][3]String{
            .{ "45%", "62%", "30%" },
            .{ "80%", "71%", "55%" },
        },
        .mode = .dos,
        .padding = 1,
        .column_align = .{ .center, .center, .center },
    };
    try writer.interface.print("=== Center-aligned (DOS mode) ===\n{f}\n", .{centered});

    // Row separators between every data row
    const with_seps = Table(2){
        .header = [_]String{ "Step", "Status" },
        .rows = &[_][2]String{
            .{ "Build", "OK" },
            .{ "Test", "OK" },
            .{ "Deploy", "PENDING" },
        },
        .padding = 1,
        .row_separator = true,
    };
    try writer.interface.print("=== Row separators ===\n{f}\n", .{with_seps});

    // Colors: per-cell foreground colors on data rows, colored header and footer
    const colored = Table(3){
        .header = [_]String{ "Service", "Status", "Uptime" },
        .rows = &[_][3]String{
            .{ "web", "UP", "99.9%" },
            .{ "db", "UP", "99.5%" },
            .{ "cache", "DOWN", "0.0%" },
        },
        .footer = [3]String{ "Summary", "2/3 UP", "" },
        .mode = .box,
        .padding = 1,
        .header_color = [3]?Color{ .bright_white, .bright_white, .bright_white },
        .footer_color = [3]?Color{ .yellow, .yellow, .yellow },
        .cell_colors = &[_][3]?Color{
            .{ null, .green, .green },
            .{ null, .green, .green },
            .{ null, .red, .red },
        },
    };
    try writer.interface.print("=== Cell colors ===\n{f}\n", .{colored});

    try writer.interface.flush();
}
