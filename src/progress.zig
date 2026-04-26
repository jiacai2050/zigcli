//! Progress bars and spinners for terminal output.

const std = @import("std");
const term = @import("term.zig");
const assert = std.debug.assert;

const ns_per_ms = std.time.ns_per_ms;

/// Minimal monotonic timer that tracks elapsed nanoseconds since creation.
/// Uses `std.Io.Clock.awake` via the runtime `Io` provided on construction.
const MonoTimer = struct {
    io: ?std.Io,
    started: std.Io.Timestamp,

    fn start(io: std.Io) MonoTimer {
        return .{
            .io = io,
            .started = std.Io.Clock.awake.now(io),
        };
    }

    /// Returns a frozen zero-valued timer. Suitable for tests where `read`
    /// is never called because callers drive elapsed time directly.
    fn zero() MonoTimer {
        return .{
            .io = null,
            .started = .{ .nanoseconds = 0 },
        };
    }

    fn read(self: MonoTimer) u64 {
        const io = self.io orelse return 0;
        const now = std.Io.Clock.awake.now(io);
        const diff = now.nanoseconds - self.started.nanoseconds;
        if (diff < 0) return 0;
        return @intCast(diff);
    }
};
const default_refresh_interval_ns: u64 = 50 * ns_per_ms;
const default_bar_width: u16 = 20;
const ellipsis = "...";
const spinner_frames = [_][]const u8{ "-", "\\", "|", "/" };
const spinner_done = "*";

const prefix_style: term.Style = .{ .bold = true };
const filled_style: term.Style = .{ .fg = .cyan };
const current_style: term.Style = .{ .fg = .bright_cyan };
const empty_style: term.Style = .{ .fg = .bright_black };
const stats_style: term.Style = .{ .fg = .bright_black };

pub const Unit = enum { items, bytes };

pub const Progress = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    use_ansi: bool,
    width_columns: ?u16,
    hidden: bool,
    refresh_interval_ns: u64,

    unit: Unit,
    bar_width: u16,
    prefix: []const u8,
    message: []const u8,

    state: State,
    timer: MonoTimer,
    last_render_elapsed_ns: ?u64,

    const Kind = enum { bar, spinner };

    const State = struct {
        kind: Kind,
        position: u64,
        total: ?u64,
        tick_count: u64,
        finished: bool,
        clear_on_finish: bool,
    };

    pub const BarOptions = struct {
        io: std.Io,
        total: u64,
        unit: Unit = .items,
        bar_width: u16 = default_bar_width,
        prefix: []const u8 = "",
        message: []const u8 = "",
        position: u64 = 0,
        file: ?std.Io.File = null,
        refresh_interval_ns: u64 = default_refresh_interval_ns,
    };

    pub const SpinnerOptions = struct {
        io: std.Io,
        unit: Unit = .items,
        prefix: []const u8 = "",
        message: []const u8 = "",
        position: u64 = 0,
        file: ?std.Io.File = null,
        refresh_interval_ns: u64 = default_refresh_interval_ns,
    };

    pub fn bar(
        gpa: std.mem.Allocator,
        options: BarOptions,
    ) Progress {
        const file = options.file orelse std.Io.File.stderr();
        const is_tty = term.isTty(file);
        return .{
            .gpa = gpa,
            .io = options.io,
            .file = file,
            .use_ansi = is_tty,
            .width_columns = term.terminalWidth(file),
            .hidden = !is_tty,
            .refresh_interval_ns = options.refresh_interval_ns,
            .unit = options.unit,
            .bar_width = options.bar_width,
            .prefix = options.prefix,
            .message = options.message,
            .state = .{
                .kind = .bar,
                .position = clampPosition(
                    options.position,
                    options.total,
                ),
                .total = options.total,
                .tick_count = 0,
                .finished = false,
                .clear_on_finish = false,
            },
            .timer = MonoTimer.start(options.io),
            .last_render_elapsed_ns = null,
        };
    }

    pub fn spinner(
        gpa: std.mem.Allocator,
        options: SpinnerOptions,
    ) Progress {
        const file = options.file orelse std.Io.File.stderr();
        const is_tty = term.isTty(file);
        return .{
            .gpa = gpa,
            .io = options.io,
            .file = file,
            .use_ansi = is_tty,
            .width_columns = term.terminalWidth(file),
            .hidden = !is_tty,
            .refresh_interval_ns = options.refresh_interval_ns,
            .unit = options.unit,
            .bar_width = 0,
            .prefix = options.prefix,
            .message = options.message,
            .state = .{
                .kind = .spinner,
                .position = options.position,
                .total = null,
                .tick_count = 0,
                .finished = false,
                .clear_on_finish = false,
            },
            .timer = MonoTimer.start(options.io),
            .last_render_elapsed_ns = null,
        };
    }

    pub fn deinit(self: *Progress) void {
        self.* = undefined;
    }

    pub fn inc(self: *Progress, delta: u64) void {
        const position = self.state.position +| delta;
        self.state.position = clampPosition(
            position,
            self.state.total,
        );
    }

    pub fn tick(self: *Progress) void {
        self.state.tick_count +|= 1;
    }

    pub fn setPosition(self: *Progress, position: u64) void {
        self.state.position = clampPosition(
            position,
            self.state.total,
        );
    }

    pub fn setMessage(self: *Progress, text: []const u8) void {
        self.message = text;
    }

    pub fn render(self: *Progress) !void {
        if (self.hidden) return;
        const elapsed_ns = self.timer.read();
        if (!self.shouldRender(elapsed_ns)) return;
        try self.flushSnapshot(elapsed_ns, false);
    }

    pub fn finish(self: *Progress) !void {
        if (self.state.finished) return;
        self.state.finished = true;
        self.state.clear_on_finish = false;
        if (self.hidden) return;
        try self.flushSnapshot(self.timer.read(), true);
    }

    pub fn finishAndClear(self: *Progress) !void {
        if (self.state.finished) {
            if (self.state.clear_on_finish) return;
        }
        self.state.finished = true;
        self.state.clear_on_finish = true;
        if (self.hidden) return;

        var output_buffer: [4096]u8 = undefined;
        var writer = self.file.writer(self.io, &output_buffer);
        if (self.use_ansi) {
            try writer.interface.writeAll("\r\x1b[2K");
        }
        try writer.interface.flush();
        self.last_render_elapsed_ns = self.timer.read();
    }

    pub fn writeSnapshot(
        self: *Progress,
        writer: *std.Io.Writer,
    ) !void {
        try self.writeSnapshotAt(
            writer,
            self.timer.read(),
            self.width_columns,
            self.use_ansi,
        );
    }

    fn flushSnapshot(
        self: *Progress,
        elapsed_ns: u64,
        append_newline: bool,
    ) !void {
        var output_buffer: [4096]u8 = undefined;
        var writer = self.file.writer(self.io, &output_buffer);
        if (self.use_ansi) {
            try writer.interface.writeAll("\r\x1b[2K");
        }
        try self.writeSnapshotAt(
            &writer.interface,
            elapsed_ns,
            self.width_columns,
            self.use_ansi,
        );
        if (append_newline) {
            try writer.interface.writeAll("\n");
        }
        try writer.interface.flush();
        self.last_render_elapsed_ns = elapsed_ns;
    }

    fn writeSnapshotAt(
        self: *Progress,
        writer: *std.Io.Writer,
        elapsed_ns: u64,
        width_columns: ?u16,
        use_ansi: bool,
    ) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const stats_text = switch (self.state.kind) {
            .bar => try self.buildBarStats(
                arena_alloc,
                elapsed_ns,
            ),
            .spinner => try self.buildSpinnerStats(
                arena_alloc,
                elapsed_ns,
            ),
        };

        const fixed = self.fixedWidth(stats_text);
        const message_limit = calculateMessageLimit(
            width_columns,
            fixed,
        );
        const visible_message = try truncateText(
            arena_alloc,
            self.message,
            message_limit,
        );

        var wrote_segment = false;

        try writeStyledSegment(
            writer,
            prefix_style,
            self.prefix,
            &wrote_segment,
            use_ansi,
        );

        switch (self.state.kind) {
            .bar => {
                if (wrote_segment) try writer.writeAll(" ");
                try writer.writeAll("[");
                try self.writeBarVisual(writer, use_ansi);
                try writer.writeAll("]");
                wrote_segment = true;
            },
            .spinner => {
                const frame = self.spinnerFrame();
                try writeStyledSegment(
                    writer,
                    filled_style,
                    frame,
                    &wrote_segment,
                    use_ansi,
                );
            },
        }

        try writeStyledSegment(
            writer,
            stats_style,
            stats_text,
            &wrote_segment,
            use_ansi,
        );
        try writeStyledSegment(
            writer,
            .{},
            visible_message,
            &wrote_segment,
            use_ansi,
        );
    }

    fn writeBarVisual(
        self: *Progress,
        writer: *std.Io.Writer,
        use_ansi: bool,
    ) !void {
        assert(self.state.total != null);
        const total = self.state.total.?;
        const width = self.bar_width;
        if (width == 0) return;

        if (total == 0) {
            for (0..width) |_| {
                try writeWithOptionalStyle(
                    writer,
                    empty_style,
                    "-",
                    use_ansi,
                );
            }
            return;
        }

        const width_u64: u64 = width;
        const filled_count: usize = @intCast(@min(
            @divFloor(self.state.position * width_u64, total),
            width_u64,
        ));
        const width_usize: usize = width;

        for (0..width_usize) |column_index| {
            if (column_index < filled_count) {
                try writeWithOptionalStyle(
                    writer,
                    filled_style,
                    "=",
                    use_ansi,
                );
            } else if (column_index == filled_count) {
                if (self.state.position < total) {
                    try writeWithOptionalStyle(
                        writer,
                        current_style,
                        ">",
                        use_ansi,
                    );
                } else {
                    try writeWithOptionalStyle(
                        writer,
                        empty_style,
                        "-",
                        use_ansi,
                    );
                }
            } else {
                try writeWithOptionalStyle(
                    writer,
                    empty_style,
                    "-",
                    use_ansi,
                );
            }
        }
    }

    fn buildBarStats(
        self: *Progress,
        arena_alloc: std.mem.Allocator,
        elapsed_ns: u64,
    ) ![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(arena_alloc);

        const total = self.state.total orelse return "";

        const percent = if (total == 0)
            0.0
        else
            100.0 *
                @as(f64, @floatFromInt(self.state.position)) /
                @as(f64, @floatFromInt(total));
        try appendToken(
            arena_alloc,
            &list,
            try std.fmt.allocPrint(
                arena_alloc,
                "{d:>5.1}%",
                .{percent},
            ),
        );

        const position_text = try formatCount(
            arena_alloc,
            self.unit,
            self.state.position,
        );
        const total_text = try formatCount(
            arena_alloc,
            self.unit,
            total,
        );
        try appendToken(
            arena_alloc,
            &list,
            try std.fmt.allocPrint(
                arena_alloc,
                "{s}/{s}",
                .{ position_text, total_text },
            ),
        );

        const elapsed_secs = nanosToSeconds(elapsed_ns);
        const rate = ratePerSecond(
            self.state.position,
            elapsed_secs,
        );
        if (rate) |rate_value| {
            const rate_text = try formatCount(
                arena_alloc,
                self.unit,
                @intFromFloat(rate_value),
            );
            try appendToken(
                arena_alloc,
                &list,
                try std.fmt.allocPrint(
                    arena_alloc,
                    "{s}/s",
                    .{rate_text},
                ),
            );
        }

        if (etaSeconds(self.state.position, total, elapsed_secs)) |eta| {
            var eta_buffer: [32]u8 = undefined;
            const eta_text = formatDurationSeconds(
                &eta_buffer,
                eta,
            );
            try appendToken(
                arena_alloc,
                &list,
                try std.fmt.allocPrint(
                    arena_alloc,
                    "ETA {s}",
                    .{eta_text},
                ),
            );
        }

        return try arena_alloc.dupe(u8, list.items);
    }

    fn buildSpinnerStats(
        self: *Progress,
        arena_alloc: std.mem.Allocator,
        elapsed_ns: u64,
    ) ![]const u8 {
        _ = self;
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(arena_alloc);

        const elapsed_secs = nanosToSeconds(elapsed_ns);
        var elapsed_buffer: [32]u8 = undefined;
        const duration_text = formatDurationSeconds(
            &elapsed_buffer,
            elapsed_secs,
        );
        try appendToken(
            arena_alloc,
            &list,
            try std.fmt.allocPrint(
                arena_alloc,
                "elapsed {s}",
                .{duration_text},
            ),
        );

        return try arena_alloc.dupe(u8, list.items);
    }

    fn fixedWidth(
        self: *Progress,
        stats_text: []const u8,
    ) usize {
        var width: usize = 0;

        if (self.prefix.len > 0) {
            width += self.prefix.len + 1;
        }

        switch (self.state.kind) {
            .bar => width += 1 + self.bar_width + 1,
            .spinner => width += self.spinnerFrame().len,
        }

        if (stats_text.len > 0) {
            width += 1 + stats_text.len;
        }

        return width;
    }

    fn spinnerFrame(self: *Progress) []const u8 {
        if (self.state.finished) return spinner_done;
        const frame_index: usize = @intCast(
            self.state.tick_count % spinner_frames.len,
        );
        return spinner_frames[frame_index];
    }

    fn shouldRender(self: *Progress, elapsed_ns: u64) bool {
        if (self.last_render_elapsed_ns) |last| {
            return (elapsed_ns - last) >= self.refresh_interval_ns;
        }
        return true;
    }
};

fn nanosToSeconds(nanos: u64) f64 {
    return @as(f64, @floatFromInt(nanos)) /
        @as(f64, @floatFromInt(std.time.ns_per_s));
}

fn ratePerSecond(position: u64, elapsed_secs: f64) ?f64 {
    if (elapsed_secs <= 0) return null;
    if (position == 0) return null;
    return @as(f64, @floatFromInt(position)) / elapsed_secs;
}

fn etaSeconds(
    position: u64,
    total: u64,
    elapsed_secs: f64,
) ?f64 {
    if (position >= total) return null;
    const rate = ratePerSecond(position, elapsed_secs) orelse
        return null;
    if (rate <= 0) return null;
    const remaining = total - position;
    return @as(f64, @floatFromInt(remaining)) / rate;
}

fn clampPosition(position: u64, total: ?u64) u64 {
    if (total) |total_value| {
        if (position > total_value) return total_value;
    }
    return position;
}

fn appendToken(
    arena_alloc: std.mem.Allocator,
    list: *std.ArrayList(u8),
    token: []const u8,
) !void {
    if (token.len == 0) return;
    if (list.items.len > 0) try list.append(arena_alloc, ' ');
    try list.appendSlice(arena_alloc, token);
}

fn calculateMessageLimit(
    width_columns: ?u16,
    fixed_width: usize,
) usize {
    const width: usize = width_columns orelse
        return std.math.maxInt(usize);
    if (width <= fixed_width + 1) return 0;
    return width - fixed_width - 1;
}

fn truncateText(
    arena_alloc: std.mem.Allocator,
    text: []const u8,
    max_width: usize,
) ![]const u8 {
    if (max_width == 0) return "";
    if (text.len <= max_width) return text;
    if (max_width <= ellipsis.len) {
        return arena_alloc.dupe(u8, text[0..max_width]);
    }
    return std.fmt.allocPrint(
        arena_alloc,
        "{s}{s}",
        .{ text[0 .. max_width - ellipsis.len], ellipsis },
    );
}

fn writeStyledSegment(
    writer: *std.Io.Writer,
    style: term.Style,
    text: []const u8,
    wrote_segment: *bool,
    use_ansi: bool,
) !void {
    if (text.len == 0) return;
    if (wrote_segment.*) try writer.writeAll(" ");
    try writeWithOptionalStyle(writer, style, text, use_ansi);
    wrote_segment.* = true;
}

fn writeWithOptionalStyle(
    writer: *std.Io.Writer,
    style: term.Style,
    text: []const u8,
    use_ansi: bool,
) !void {
    if (use_ansi) {
        try style.writeString(writer, "{s}", .{text});
    } else {
        try writer.writeAll(text);
    }
}

fn formatCount(
    arena_alloc: std.mem.Allocator,
    unit: Unit,
    value: u64,
) ![]const u8 {
    return switch (unit) {
        .items => std.fmt.allocPrint(
            arena_alloc,
            "{d}",
            .{value},
        ),
        .bytes => formatBytes(arena_alloc, value),
    };
}

fn formatBytes(
    arena_alloc: std.mem.Allocator,
    value: u64,
) ![]const u8 {
    const units = [_][]const u8{
        "B", "KiB", "MiB", "GiB", "TiB",
    };
    var value_f64: f64 = @floatFromInt(value);
    var unit_index: usize = 0;
    while (value_f64 >= 1024.0) {
        if (unit_index >= units.len - 1) break;
        value_f64 /= 1024.0;
        unit_index += 1;
    }
    return std.fmt.allocPrint(
        arena_alloc,
        "{d:.1} {s}",
        .{ value_f64, units[unit_index] },
    );
}

fn formatDurationSeconds(
    buffer: []u8,
    seconds: f64,
) []const u8 {
    assert(buffer.len >= 12);
    const total_secs = @as(
        u64,
        @intFromFloat(@max(seconds, 0)),
    );
    const hours = total_secs / 3600;
    const minutes = (total_secs % 3600) / 60;
    const secs = total_secs % 60;
    if (hours > 0) {
        return std.fmt.bufPrint(
            buffer,
            "{d}:{d:0>2}:{d:0>2}",
            .{ hours, minutes, secs },
        ) catch unreachable;
    }
    return std.fmt.bufPrint(
        buffer,
        "{d}:{d:0>2}",
        .{ minutes, secs },
    ) catch unreachable;
}

fn testProgress(kind: Progress.Kind, options: struct {
    total: ?u64 = null,
    unit: Unit = .items,
    bar_width: u16 = default_bar_width,
    prefix: []const u8 = "",
    message: []const u8 = "",
    width_columns: ?u16 = 120,
    refresh_interval_ns: u64 = default_refresh_interval_ns,
}) Progress {
    const io = std.testing.io;
    return .{
        .gpa = std.testing.allocator,
        .io = io,
        .file = std.Io.File.stdout(),
        .use_ansi = false,
        .width_columns = options.width_columns,
        .hidden = false,
        .refresh_interval_ns = options.refresh_interval_ns,
        .unit = options.unit,
        .bar_width = options.bar_width,
        .prefix = options.prefix,
        .message = options.message,
        .state = .{
            .kind = kind,
            .position = 0,
            .total = options.total,
            .tick_count = 0,
            .finished = false,
            .clear_on_finish = false,
        },
        .timer = MonoTimer.zero(),
        .last_render_elapsed_ns = null,
    };
}

test "bar snapshot: verify percent, position, rate, ETA, and message" {
    var progress = testProgress(.bar, .{
        .total = 100,
        .message = "downloading",
    });
    defer progress.deinit();

    progress.setPosition(25);

    var allocating: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer allocating.deinit();

    const elapsed_ns = 2 * std.time.ns_per_s;
    try progress.writeSnapshotAt(
        &allocating.writer,
        elapsed_ns,
        120,
        false,
    );
    try std.testing.expectEqualStrings(
        "[=====>--------------]" ++
            "  25.0% 25/100 12/s ETA 0:06 downloading",
        allocating.written(),
    );
}

test "spinner snapshot: verify elapsed time and message" {
    var progress = testProgress(.spinner, .{
        .message = "waiting",
    });
    defer progress.deinit();

    progress.tick();
    progress.tick();

    var allocating: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer allocating.deinit();

    const elapsed_ns = 3500 * std.time.ns_per_ms;
    try progress.writeSnapshotAt(
        &allocating.writer,
        elapsed_ns,
        120,
        false,
    );
    try std.testing.expectEqualStrings(
        "| elapsed 0:03 waiting",
        allocating.written(),
    );
}

test "message truncation: long messages clipped to terminal width" {
    var progress = testProgress(.bar, .{
        .total = 10,
        .message = "this-message-is-too-long",
        .width_columns = 32,
    });
    defer progress.deinit();

    progress.setPosition(5);

    var allocating: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer allocating.deinit();

    const elapsed_ns = 1 * std.time.ns_per_s;
    try progress.writeSnapshotAt(
        &allocating.writer,
        elapsed_ns,
        32,
        false,
    );
    try std.testing.expectEqualStrings(
        "[==========>---------]  50.0% 5/10 5/s ETA 0:01",
        allocating.written(),
    );
}

test "throttle: render is skipped when within refresh interval" {
    const interval_ns = 100 * ns_per_ms;
    var progress = testProgress(.bar, .{
        .total = 10,
        .refresh_interval_ns = interval_ns,
    });
    defer progress.deinit();

    progress.last_render_elapsed_ns = 90 * ns_per_ms;

    // 10ms after last render: should be suppressed.
    try std.testing.expect(
        !progress.shouldRender(100 * ns_per_ms),
    );

    // 200ms after start, 110ms after last render: allowed.
    try std.testing.expect(
        progress.shouldRender(200 * ns_per_ms),
    );
}

test "finishAndClear: finished bar still renders a snapshot" {
    // Verify that writeSnapshotAt produces output even after
    // finish+clear, since clearing is a terminal operation
    // handled by flushSnapshot, not the snapshot itself.
    var progress = testProgress(.bar, .{ .total = 10 });
    defer progress.deinit();

    progress.state.finished = true;
    progress.state.clear_on_finish = true;
    progress.use_ansi = true;

    var allocating: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer allocating.deinit();

    try progress.writeSnapshotAt(
        &allocating.writer,
        1 * std.time.ns_per_s,
        120,
        true,
    );

    try std.testing.expect(allocating.written().len > 0);
}
