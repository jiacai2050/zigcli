const std = @import("std");
const zigcli = @import("zigcli");
const progress = zigcli.progress;

pub fn main() !void {
    const stderr = std.fs.File.stderr();
    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = stderr.writer(&stderr_buffer);

    try writeSectionHeading(&stderr_writer.interface, "Single progress bar");
    try demoBar();
    try writeSectionHeading(&stderr_writer.interface, "Custom bar width");
    try demoWideBar();
    try writeSectionHeading(&stderr_writer.interface, "Spinner");
    try demoSpinner();
    try stderr_writer.interface.writeAll("\n");
    try stderr_writer.interface.flush();
}

fn writeSectionHeading(
    writer: *std.Io.Writer,
    title: []const u8,
) !void {
    try writer.print("\n=== {s} ===\n", .{title});
    try writer.flush();
}

fn demoBar() !void {
    const total = 20;
    var bar = progress.Progress.bar(std.heap.page_allocator, .{
        .total = total,
        .message = "copying files",
        .prefix = "bar",
    });
    defer bar.deinit();

    for (0..total) |_| {
        bar.inc(1);
        try bar.render();
        std.Thread.sleep(120 * std.time.ns_per_ms);
    }
    try bar.finish();
}

fn demoWideBar() !void {
    const total = 16;
    var bar = progress.Progress.bar(std.heap.page_allocator, .{
        .total = total,
        .bar_width = 40,
        .message = "wide bar",
        .prefix = "wide",
    });
    defer bar.deinit();

    for (0..total) |_| {
        bar.inc(1);
        try bar.render();
        std.Thread.sleep(110 * std.time.ns_per_ms);
    }
    try bar.finish();
}

fn demoSpinner() !void {
    const tick_count = 16;
    var spinner = progress.Progress.spinner(
        std.heap.page_allocator,
        .{
            .message = "resolving dependencies",
            .prefix = "spin",
        },
    );
    defer spinner.deinit();

    for (0..tick_count) |_| {
        spinner.tick();
        try spinner.render();
        std.Thread.sleep(140 * std.time.ns_per_ms);
    }
    try spinner.finish();
}
