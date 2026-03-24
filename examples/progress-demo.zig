const std = @import("std");
const zigcli = @import("zigcli");
const progress = zigcli.progress;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stderr = std.fs.File.stderr();
    var stderr_buffer: [2048]u8 = undefined;
    var out = stderr.writer(&stderr_buffer);

    try writeSectionHeading(&out.interface, "Single progress bar");
    try demoBar(allocator);
    try writeSectionHeading(&out.interface, "Custom bar width");
    try demoWideBar(allocator);
    try writeSectionHeading(&out.interface, "Spinner");
    try demoSpinner(allocator);
    try writeSectionHeading(&out.interface, "Multi-progress");
    try demoMulti(allocator);
    try writeSectionHeading(&out.interface, "Writer wrapper");
    try demoWrapWriter(allocator, &out.interface);
    try out.interface.writeAll("\n");
    try out.interface.flush();
}

fn writeSectionHeading(
    writer: *std.Io.Writer,
    title: []const u8,
) !void {
    try writer.print("\n=== {s} ===\n", .{title});
    try writer.flush();
}

fn demoBar(allocator: std.mem.Allocator) !void {
    var bar = try progress.Progress.bar(allocator, .{
        .total = 20,
        .style = progress.Style.defaultBar(),
        .message = "copying files",
        .prefix = "bar",
    });
    defer bar.deinit();

    for (0..20) |_| {
        bar.inc(1);
        try bar.render();
        std.Thread.sleep(120 * std.time.ns_per_ms);
    }
    try bar.finish();
}

fn demoWideBar(allocator: std.mem.Allocator) !void {
    var style = progress.Style.defaultBar();
    style.bar_width = 40;

    var bar = try progress.Progress.bar(allocator, .{
        .total = 16,
        .style = style,
        .message = "wide bar",
        .prefix = "wide",
    });
    defer bar.deinit();

    for (0..16) |_| {
        bar.inc(1);
        try bar.render();
        std.Thread.sleep(110 * std.time.ns_per_ms);
    }
    try bar.finish();
}

fn demoSpinner(allocator: std.mem.Allocator) !void {
    var spinner = try progress.Progress.spinner(allocator, .{
        .style = progress.Style.defaultSpinner(),
        .message = "resolving dependencies",
        .prefix = "spin",
    });
    defer spinner.deinit();

    for (0..16) |_| {
        spinner.tick();
        try spinner.render();
        std.Thread.sleep(140 * std.time.ns_per_ms);
    }
    try spinner.finish();
}

fn demoMulti(allocator: std.mem.Allocator) !void {
    var multi = progress.MultiProgress.init(allocator, .{});
    defer multi.deinit();

    const download = try multi.addBar(.{
        .total = 12,
        .message = "download",
        .prefix = "task-1",
    });
    const unpack = try multi.addSpinner(.{
        .message = "unpack",
        .prefix = "task-2",
    });

    for (0..12) |_| {
        download.inc(1);
        unpack.tick();
        try multi.render();
        std.Thread.sleep(130 * std.time.ns_per_ms);
    }

    try download.finish();
    try unpack.finish();
    try multi.render();
}

fn demoWrapWriter(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    var bar = try progress.Progress.bar(allocator, .{
        .total = 5 * 8,
        .style = .{
            .unit = .bytes,
        },
        .message = "writing chunks",
        .prefix = "io",
    });
    defer bar.deinit();

    var sink: std.Io.Writer.Allocating = .init(allocator);
    var wrapped = bar.wrapWriter(&sink.writer);

    inline for (.{
        "chunk-01",
        "chunk-02",
        "chunk-03",
        "chunk-04",
        "chunk-05",
    }) |chunk| {
        try wrapped.writeAll(chunk);
        try bar.render();
        std.Thread.sleep(160 * std.time.ns_per_ms);
    }

    try bar.finish();
    try writer.print(
        "Captured {d} bytes through ProgressWriter.\n",
        .{sink.written().len},
    );
    sink.deinit();
}
