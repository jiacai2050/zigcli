const info = @import("build_info");

pub fn print_build_info(writer: anytype) !void {
    try writer.print("Build date: {s}\nGit commit: {s}", .{ info.build_date, info.git_commit });
}
