const std = @import("std");

const Table = @import("pretty-table").Table;
const Separator = @import("pretty-table").Separator;
const String = @import("pretty-table").String;

pub fn main() !void {
    const t = Table(2){
        .header = [_]String{ "Language", "Files" },
        .rows = &[_][2]String{
            .{ "Zig", "3" },
            .{ "Python", "2" },
            .{ "C", "12" },
            .{ "Ruby", "5" },
        },
        .footer = [2]String{ "Total", "22" },
        .mode = .box,
    };

    const out = std.fs.File.stdout();
    var buf: [1024]u8 = undefined;
    var writer = out.writer(&buf);

    try writer.interface.print("{f}", .{t});
    try writer.interface.flush();
}
