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

    const out = std.io.getStdOut();
    try out.writer().print("{}", .{t});
}
