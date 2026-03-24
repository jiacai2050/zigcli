//! progress provides reusable progress bars, spinners, and multi-progress rendering.

const std = @import("std");
const term = @import("term.zig");
const assert = std.debug.assert;

const default_refresh_interval_ms: u32 = 50;
const default_bar_width: u16 = 20;
const ellipsis = "...";
const default_spinner_frames = [_][]const u8{ "-", "\\", "|", "/" };

fn nowMilliseconds() u64 {
    const now_ms = std.time.milliTimestamp();
    assert(now_ms >= 0);
    return @intCast(now_ms);
}

pub const DrawTarget = struct {
    file: std.fs.File,
    hidden: bool,
    use_ansi: bool,
    width_columns: ?u16,
    refresh_interval_ms: u32,

    pub const Options = struct {
        hide_when_not_tty: bool = true,
        hidden: ?bool = null,
        use_ansi: bool = true,
        width_columns: ?u16 = null,
        refresh_interval_ms: u32 = default_refresh_interval_ms,
    };

    pub fn stderr() DrawTarget {
        return fromFile(std.fs.File.stderr(), .{});
    }

    pub fn stdout() DrawTarget {
        return fromFile(std.fs.File.stdout(), .{});
    }

    pub fn fromFile(
        file: std.fs.File,
        options: Options,
    ) DrawTarget {
        const is_tty = term.isTty(file);
        const hidden = options.hidden orelse
            (options.hide_when_not_tty and !is_tty);
        return .{
            .file = file,
            .hidden = hidden,
            .use_ansi = options.use_ansi and is_tty,
            .width_columns = options.width_columns orelse term.terminalWidth(file),
            .refresh_interval_ms = options.refresh_interval_ms,
        };
    }
};

pub const Style = struct {
    pub const Unit = enum {
        items,
        bytes,
    };

    show_prefix: bool = true,
    show_message: bool = true,
    show_percent: bool = true,
    show_position: bool = true,
    show_rate: bool = true,
    show_eta: bool = true,
    show_elapsed: bool = false,
    unit: Unit = .items,
    bar_width: u16 = default_bar_width,
    bar_left: []const u8 = "[",
    bar_right: []const u8 = "]",
    filled: []const u8 = "=",
    current: []const u8 = ">",
    empty: []const u8 = "-",
    spinner_frames: []const []const u8 = &default_spinner_frames,
    spinner_done: []const u8 = "*",
    prefix_style: term.Style = .{
        .bold = true,
    },
    message_style: term.Style = .{},
    filled_style: term.Style = .{
        .fg = .cyan,
    },
    current_style: term.Style = .{
        .fg = .bright_cyan,
    },
    empty_style: term.Style = .{
        .fg = .bright_black,
    },
    stats_style: term.Style = .{
        .fg = .bright_black,
    },

    pub fn defaultBar() Style {
        return .{};
    }

    pub fn defaultSpinner() Style {
        return .{
            .show_percent = false,
            .show_position = false,
            .show_rate = false,
            .show_eta = false,
            .show_elapsed = true,
            .bar_width = 0,
        };
    }
};

pub const Progress = struct {
    gpa: std.mem.Allocator,
    draw_target: DrawTarget,
    style: Style,
    prefix: std.ArrayList(u8),
    message: std.ArrayList(u8),
    state: State,
    last_render_at_ms: ?u64,
    managed_by_multi: bool,

    const ProgressKind = enum {
        bar,
        spinner,
    };

    const State = struct {
        kind: ProgressKind,
        position: u64,
        total: ?u64,
        started_at_ms: u64,
        tick_count: u64,
        finished: bool,
        clear_on_finish: bool,
    };

    pub const BarOptions = struct {
        total: u64,
        draw_target: ?DrawTarget = null,
        style: Style = Style.defaultBar(),
        prefix: []const u8 = "",
        message: []const u8 = "",
        position: u64 = 0,
    };

    pub const SpinnerOptions = struct {
        draw_target: ?DrawTarget = null,
        style: Style = Style.defaultSpinner(),
        prefix: []const u8 = "",
        message: []const u8 = "",
        position: u64 = 0,
    };

    const RenderBehavior = struct {
        force: bool,
        interactive: bool,
        width_columns: ?u16,
        hidden: bool,
        append_newline: bool,
    };

    pub fn bar(
        gpa: std.mem.Allocator,
        options: BarOptions,
    ) !Progress {
        return init(gpa, .bar, options.draw_target, options.style, .{
            .prefix = options.prefix,
            .message = options.message,
            .position = options.position,
            .total = options.total,
        });
    }

    pub fn spinner(
        gpa: std.mem.Allocator,
        options: SpinnerOptions,
    ) !Progress {
        return init(gpa, .spinner, options.draw_target, options.style, .{
            .prefix = options.prefix,
            .message = options.message,
            .position = options.position,
            .total = null,
        });
    }

    fn init(
        gpa: std.mem.Allocator,
        kind: ProgressKind,
        draw_target: ?DrawTarget,
        style: Style,
        init_options: struct {
            prefix: []const u8,
            message: []const u8,
            position: u64,
            total: ?u64,
        },
    ) !Progress {
        switch (kind) {
            .bar => {
                assert(init_options.total != null);
            },
            .spinner => {
                assert(init_options.total == null);
                assert(style.spinner_frames.len > 0);
            },
        }

        var prefix: std.ArrayList(u8) = .empty;
        errdefer prefix.deinit(gpa);
        try prefix.appendSlice(gpa, init_options.prefix);

        var message: std.ArrayList(u8) = .empty;
        errdefer message.deinit(gpa);
        try message.appendSlice(gpa, init_options.message);

        const started_at_ms = nowMilliseconds();
        return .{
            .gpa = gpa,
            .draw_target = draw_target orelse DrawTarget.stderr(),
            .style = style,
            .prefix = prefix,
            .message = message,
            .state = .{
                .kind = kind,
                .position = clampPosition(init_options.position, init_options.total),
                .total = init_options.total,
                .started_at_ms = started_at_ms,
                .tick_count = 0,
                .finished = false,
                .clear_on_finish = false,
            },
            .last_render_at_ms = null,
            .managed_by_multi = false,
        };
    }

    pub fn deinit(self: *Progress) void {
        self.prefix.deinit(self.gpa);
        self.message.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn setMessage(
        self: *Progress,
        text: []const u8,
    ) !void {
        try setText(self.gpa, &self.message, text);
    }

    pub fn setPrefix(
        self: *Progress,
        text: []const u8,
    ) !void {
        try setText(self.gpa, &self.prefix, text);
    }

    pub fn setPosition(
        self: *Progress,
        position: u64,
    ) void {
        self.state.position = clampPosition(position, self.state.total);
    }

    pub fn setTotal(
        self: *Progress,
        total: u64,
    ) void {
        self.state.total = total;
        self.state.position = clampPosition(self.state.position, self.state.total);
    }

    pub fn inc(
        self: *Progress,
        delta: u64,
    ) void {
        const position = self.state.position +| delta;
        self.state.position = clampPosition(position, self.state.total);
    }

    pub fn tick(self: *Progress) void {
        self.state.tick_count +|= 1;
    }

    pub fn writeSnapshot(
        self: *Progress,
        writer: *std.Io.Writer,
    ) !void {
        try self.writeSnapshotAt(
            writer,
            nowMilliseconds(),
            self.draw_target.width_columns,
            self.draw_target.use_ansi,
        );
    }

    pub fn render(self: *Progress) !void {
        try self.renderInternal(.{
            .force = true,
            .interactive = self.draw_target.use_ansi and !self.managed_by_multi,
            .width_columns = self.draw_target.width_columns,
            .hidden = self.draw_target.hidden,
            .append_newline = false,
        });
    }

    pub fn renderThrottled(self: *Progress) !void {
        try self.renderInternal(.{
            .force = false,
            .interactive = self.draw_target.use_ansi and !self.managed_by_multi,
            .width_columns = self.draw_target.width_columns,
            .hidden = self.draw_target.hidden,
            .append_newline = false,
        });
    }

    pub fn finish(self: *Progress) !void {
        if (self.state.finished) {
            return;
        }
        self.state.finished = true;
        self.state.clear_on_finish = false;
        try self.renderInternal(.{
            .force = true,
            .interactive = self.draw_target.use_ansi and !self.managed_by_multi,
            .width_columns = self.draw_target.width_columns,
            .hidden = self.draw_target.hidden,
            .append_newline = !self.draw_target.hidden and !self.managed_by_multi,
        });
    }

    pub fn finishAndClear(self: *Progress) !void {
        if (self.state.finished and self.state.clear_on_finish) {
            return;
        }
        self.state.finished = true;
        self.state.clear_on_finish = true;
        try self.renderInternal(.{
            .force = true,
            .interactive = self.draw_target.use_ansi and !self.managed_by_multi,
            .width_columns = self.draw_target.width_columns,
            .hidden = self.draw_target.hidden,
            .append_newline = false,
        });
    }

    pub fn wrapWriter(
        self: *Progress,
        writer: anytype,
    ) ProgressWriter(@TypeOf(writer)) {
        return .{
            .inner = writer,
            .progress = self,
        };
    }

    pub fn wrapReader(
        self: *Progress,
        reader: anytype,
    ) ProgressReader(@TypeOf(reader)) {
        return .{
            .inner = reader,
            .progress = self,
        };
    }

    fn renderInternal(
        self: *Progress,
        behavior: RenderBehavior,
    ) !void {
        if (behavior.hidden) {
            return;
        }

        const now_ms = nowMilliseconds();
        if (!behavior.force and !self.shouldRenderAt(now_ms)) {
            return;
        }

        var output_buffer: [4096]u8 = undefined;
        var writer = self.draw_target.file.writer(&output_buffer);
        try self.renderToWriterAt(
            &writer.interface,
            now_ms,
            behavior,
        );
        try writer.interface.flush();
    }

    fn renderToWriterAt(
        self: *Progress,
        writer: *std.Io.Writer,
        now_ms: u64,
        behavior: RenderBehavior,
    ) !void {
        if (behavior.hidden) {
            return;
        }

        if (!behavior.force and !self.shouldRenderAt(now_ms)) {
            return;
        }

        if (self.state.finished and self.state.clear_on_finish) {
            if (behavior.interactive) {
                try writer.writeAll("\r\x1b[2K");
            }
            self.last_render_at_ms = now_ms;
            return;
        }

        if (behavior.interactive) {
            try writer.writeAll("\r\x1b[2K");
        }
        try self.writeSnapshotAt(
            writer,
            now_ms,
            behavior.width_columns,
            behavior.interactive,
        );
        if (behavior.append_newline) {
            try writer.writeAll("\n");
        }
        self.last_render_at_ms = now_ms;
    }

    fn writeSnapshotAt(
        self: *Progress,
        writer: *std.Io.Writer,
        now_ms: u64,
        width_columns: ?u16,
        use_ansi: bool,
    ) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const prefix_text = if (self.style.show_prefix)
            self.prefix.items
        else
            "";
        const message_text = if (self.style.show_message)
            self.message.items
        else
            "";

        const stats_text = switch (self.state.kind) {
            .bar => try self.buildBarStats(arena_allocator, now_ms),
            .spinner => try self.buildSpinnerStats(arena_allocator, now_ms),
        };

        const fixed_width = self.fixedWidth(prefix_text, stats_text);
        const message_limit = calculateMessageLimit(width_columns, fixed_width);
        const visible_message = try truncateText(
            arena_allocator,
            message_text,
            message_limit,
        );

        switch (self.state.kind) {
            .bar => try self.writeBarLine(
                writer,
                prefix_text,
                visible_message,
                stats_text,
                use_ansi,
            ),
            .spinner => try self.writeSpinnerLine(
                writer,
                prefix_text,
                visible_message,
                stats_text,
                use_ansi,
            ),
        }
    }

    fn writeBarLine(
        self: *Progress,
        writer: *std.Io.Writer,
        prefix_text: []const u8,
        message_text: []const u8,
        stats_text: []const u8,
        use_ansi: bool,
    ) !void {
        var wrote_segment = false;
        try writeStyledSegment(
            writer,
            self.style.prefix_style,
            prefix_text,
            &wrote_segment,
            use_ansi,
        );

        if (wrote_segment) {
            try writer.writeAll(" ");
        }
        try writer.writeAll(self.style.bar_left);
        try self.writeBarVisual(writer, use_ansi);
        try writer.writeAll(self.style.bar_right);
        wrote_segment = true;

        try writeStyledSegment(
            writer,
            self.style.stats_style,
            stats_text,
            &wrote_segment,
            use_ansi,
        );
        try writeStyledSegment(
            writer,
            self.style.message_style,
            message_text,
            &wrote_segment,
            use_ansi,
        );
    }

    fn writeSpinnerLine(
        self: *Progress,
        writer: *std.Io.Writer,
        prefix_text: []const u8,
        message_text: []const u8,
        stats_text: []const u8,
        use_ansi: bool,
    ) !void {
        var wrote_segment = false;
        try writeStyledSegment(
            writer,
            self.style.prefix_style,
            prefix_text,
            &wrote_segment,
            use_ansi,
        );

        const frame = self.spinnerFrame();
        try writeStyledSegment(
            writer,
            self.style.filled_style,
            frame,
            &wrote_segment,
            use_ansi,
        );
        try writeStyledSegment(
            writer,
            self.style.stats_style,
            stats_text,
            &wrote_segment,
            use_ansi,
        );
        try writeStyledSegment(
            writer,
            self.style.message_style,
            message_text,
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
        const width = self.style.bar_width;
        if (width == 0) {
            return;
        }

        if (total == 0) {
            for (0..width) |_| {
                try writeWithOptionalStyle(
                    writer,
                    self.style.empty_style,
                    self.style.empty,
                    use_ansi,
                );
            }
            return;
        }

        const width_u64: u64 = width;
        const filled_count_u64 = @divFloor(
            self.state.position * width_u64,
            total,
        );
        const filled_count: usize = @intCast(@min(filled_count_u64, width_u64));
        const width_usize: usize = width;

        for (0..width_usize) |column_index| {
            if (column_index < filled_count) {
                try writeWithOptionalStyle(
                    writer,
                    self.style.filled_style,
                    self.style.filled,
                    use_ansi,
                );
                continue;
            }

            const has_head = self.state.position < total;
            if (has_head and column_index == filled_count) {
                try writeWithOptionalStyle(
                    writer,
                    self.style.current_style,
                    self.style.current,
                    use_ansi,
                );
            } else {
                try writeWithOptionalStyle(
                    writer,
                    self.style.empty_style,
                    self.style.empty,
                    use_ansi,
                );
            }
        }
    }

    fn buildBarStats(
        self: *Progress,
        arena: std.mem.Allocator,
        now_ms: u64,
    ) ![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(arena);

        const maybe_total = self.state.total;
        if (self.style.show_percent) {
            if (maybe_total) |total| {
                const percent = if (total == 0)
                    0.0
                else
                    100.0 * @as(f64, @floatFromInt(self.state.position)) /
                        @as(f64, @floatFromInt(total));
                try appendToken(arena, &list, try std.fmt.allocPrint(
                    arena,
                    "{d:>5.1}%",
                    .{percent},
                ));
            }
        }

        if (self.style.show_position) {
            if (maybe_total) |total| {
                const position_text = try formatCount(arena, self.style.unit, self.state.position);
                const total_text = try formatCount(arena, self.style.unit, total);
                try appendToken(arena, &list, try std.fmt.allocPrint(
                    arena,
                    "{s}/{s}",
                    .{ position_text, total_text },
                ));
            } else {
                try appendToken(arena, &list, try formatCount(
                    arena,
                    self.style.unit,
                    self.state.position,
                ));
            }
        }

        if (self.style.show_rate) {
            const rate = self.ratePerSecond(now_ms) orelse 0.0;
            if (rate > 0) {
                const rate_text = try formatCount(
                    arena,
                    self.style.unit,
                    @intFromFloat(rate),
                );
                try appendToken(arena, &list, try std.fmt.allocPrint(
                    arena,
                    "{s}/s",
                    .{rate_text},
                ));
            }
        }

        if (self.style.show_eta) {
            if (self.etaSeconds(now_ms)) |eta_seconds| {
                var eta_buffer: [32]u8 = undefined;
                const eta_text = formatDurationSeconds(&eta_buffer, eta_seconds);
                try appendToken(arena, &list, try std.fmt.allocPrint(
                    arena,
                    "ETA {s}",
                    .{eta_text},
                ));
            }
        }

        if (self.style.show_elapsed) {
            const elapsed_text = try self.formatElapsed(arena, now_ms);
            try appendToken(arena, &list, elapsed_text);
        }

        return try arena.dupe(u8, list.items);
    }

    fn buildSpinnerStats(
        self: *Progress,
        arena: std.mem.Allocator,
        now_ms: u64,
    ) ![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(arena);

        if (self.style.show_position) {
            const count_text = try formatCount(
                arena,
                self.style.unit,
                self.state.position,
            );
            try appendToken(arena, &list, count_text);
        }

        if (self.style.show_rate) {
            const rate = self.ratePerSecond(now_ms) orelse 0.0;
            if (rate > 0) {
                const rate_text = try formatCount(
                    arena,
                    self.style.unit,
                    @intFromFloat(rate),
                );
                try appendToken(arena, &list, try std.fmt.allocPrint(
                    arena,
                    "{s}/s",
                    .{rate_text},
                ));
            }
        }

        if (self.style.show_elapsed) {
            const elapsed_text = try self.formatElapsed(arena, now_ms);
            try appendToken(arena, &list, elapsed_text);
        }

        return try arena.dupe(u8, list.items);
    }

    fn formatElapsed(
        self: *Progress,
        arena: std.mem.Allocator,
        now_ms: u64,
    ) ![]const u8 {
        const elapsed_seconds = elapsedSeconds(self.state.started_at_ms, now_ms);
        var buffer: [32]u8 = undefined;
        const duration_text = formatDurationSeconds(&buffer, elapsed_seconds);
        return std.fmt.allocPrint(arena, "elapsed {s}", .{duration_text});
    }

    fn fixedWidth(
        self: *Progress,
        prefix_text: []const u8,
        stats_text: []const u8,
    ) usize {
        var width: usize = 0;

        if (prefix_text.len > 0 and self.style.show_prefix) {
            width += prefix_text.len + 1;
        }

        switch (self.state.kind) {
            .bar => {
                width += self.style.bar_left.len;
                width += self.style.bar_width;
                width += self.style.bar_right.len;
            },
            .spinner => {
                width += self.spinnerFrame().len;
            },
        }

        if (stats_text.len > 0) {
            width += 1 + stats_text.len;
        }

        return width;
    }

    fn spinnerFrame(self: *Progress) []const u8 {
        if (self.state.finished) {
            return self.style.spinner_done;
        }

        const frame_count = self.style.spinner_frames.len;
        assert(frame_count > 0);
        const frame_index = @as(usize, @intCast(self.state.tick_count % frame_count));
        return self.style.spinner_frames[frame_index];
    }

    fn ratePerSecond(
        self: *Progress,
        now_ms: u64,
    ) ?f64 {
        const elapsed_seconds = elapsedSeconds(self.state.started_at_ms, now_ms);
        if (elapsed_seconds <= 0) {
            return null;
        }
        if (self.state.position == 0) {
            return null;
        }
        return @as(f64, @floatFromInt(self.state.position)) / elapsed_seconds;
    }

    fn etaSeconds(
        self: *Progress,
        now_ms: u64,
    ) ?f64 {
        const total = self.state.total orelse return null;
        if (self.state.position >= total) {
            return null;
        }
        const rate = self.ratePerSecond(now_ms) orelse return null;
        if (rate <= 0) {
            return null;
        }
        const remaining = total - self.state.position;
        return @as(f64, @floatFromInt(remaining)) / rate;
    }

    fn shouldRenderAt(
        self: *Progress,
        now_ms: u64,
    ) bool {
        if (self.last_render_at_ms) |last_render_at_ms| {
            const elapsed_ms = now_ms - last_render_at_ms;
            return elapsed_ms >= self.draw_target.refresh_interval_ms;
        }
        return true;
    }
};

pub fn ProgressWriter(comptime WriterType: type) type {
    return struct {
        inner: WriterType,
        progress: *Progress,

        const Self = @This();

        pub fn write(
            self: *Self,
            bytes: []const u8,
        ) !usize {
            const written = try self.inner.write(bytes);
            self.progress.inc(@intCast(written));
            try self.progress.renderThrottled();
            return written;
        }

        pub fn writeAll(
            self: *Self,
            bytes: []const u8,
        ) !void {
            try self.inner.writeAll(bytes);
            self.progress.inc(@intCast(bytes.len));
            try self.progress.renderThrottled();
        }
    };
}

pub fn ProgressReader(comptime ReaderType: type) type {
    return struct {
        inner: ReaderType,
        progress: *Progress,

        const Self = @This();

        pub fn read(
            self: *Self,
            bytes: []u8,
        ) !usize {
            const read_count = try self.inner.read(bytes);
            self.progress.inc(@intCast(read_count));
            try self.progress.renderThrottled();
            return read_count;
        }
    };
}

pub const MultiProgress = struct {
    gpa: std.mem.Allocator,
    draw_target: DrawTarget,
    items: std.ArrayList(*Progress),
    last_render_at_ms: ?u64,
    rendered_line_count: u32,

    pub const Options = struct {
        draw_target: ?DrawTarget = null,
    };

    const RenderBehavior = struct {
        force: bool,
    };

    pub fn init(
        gpa: std.mem.Allocator,
        options: Options,
    ) MultiProgress {
        return .{
            .gpa = gpa,
            .draw_target = options.draw_target orelse DrawTarget.stderr(),
            .items = .empty,
            .last_render_at_ms = null,
            .rendered_line_count = 0,
        };
    }

    pub fn deinit(self: *MultiProgress) void {
        for (self.items.items) |progress| {
            progress.deinit();
            self.gpa.destroy(progress);
        }
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn addBar(
        self: *MultiProgress,
        options: Progress.BarOptions,
    ) !*Progress {
        var adjusted = options;
        adjusted.draw_target = self.draw_target;
        const progress_ptr = try self.gpa.create(Progress);
        errdefer self.gpa.destroy(progress_ptr);
        progress_ptr.* = try Progress.bar(self.gpa, adjusted);
        progress_ptr.managed_by_multi = true;
        try self.items.append(self.gpa, progress_ptr);
        return progress_ptr;
    }

    pub fn addSpinner(
        self: *MultiProgress,
        options: Progress.SpinnerOptions,
    ) !*Progress {
        var adjusted = options;
        adjusted.draw_target = self.draw_target;
        const progress_ptr = try self.gpa.create(Progress);
        errdefer self.gpa.destroy(progress_ptr);
        progress_ptr.* = try Progress.spinner(self.gpa, adjusted);
        progress_ptr.managed_by_multi = true;
        try self.items.append(self.gpa, progress_ptr);
        return progress_ptr;
    }

    pub fn remove(
        self: *MultiProgress,
        progress_ptr: *Progress,
    ) bool {
        for (self.items.items, 0..) |item, item_index| {
            if (item != progress_ptr) {
                continue;
            }

            _ = self.items.orderedRemove(item_index);
            item.deinit();
            self.gpa.destroy(item);
            return true;
        }
        return false;
    }

    pub fn writeSnapshot(
        self: *MultiProgress,
        writer: *std.Io.Writer,
    ) !void {
        try self.writeSnapshotAt(
            writer,
            nowMilliseconds(),
            self.draw_target.width_columns,
            self.draw_target.use_ansi,
        );
    }

    pub fn render(self: *MultiProgress) !void {
        try self.renderInternal(.{ .force = true });
    }

    pub fn renderThrottled(self: *MultiProgress) !void {
        try self.renderInternal(.{ .force = false });
    }

    fn renderInternal(
        self: *MultiProgress,
        behavior: RenderBehavior,
    ) !void {
        if (self.draw_target.hidden) {
            return;
        }

        const now_ms = nowMilliseconds();
        if (!behavior.force and !self.shouldRenderAt(now_ms)) {
            return;
        }

        var output_buffer: [8192]u8 = undefined;
        var writer = self.draw_target.file.writer(&output_buffer);
        try self.renderToWriterAt(
            &writer.interface,
            now_ms,
            behavior.force,
        );
        try writer.interface.flush();
    }

    fn renderToWriterAt(
        self: *MultiProgress,
        writer: *std.Io.Writer,
        now_ms: u64,
        force: bool,
    ) !void {
        if (self.draw_target.hidden) {
            return;
        }

        if (!force and !self.shouldRenderAt(now_ms)) {
            return;
        }

        const visible_count = self.visibleCount();
        const line_count = @max(self.rendered_line_count, visible_count);

        if (self.draw_target.use_ansi and self.rendered_line_count > 0) {
            try writer.writeAll("\r");
            if (self.rendered_line_count > 1) {
                try writer.print("\x1b[{d}A", .{self.rendered_line_count - 1});
            }
        }

        var visible_index: u32 = 0;
        var line_index: u32 = 0;
        while (line_index < line_count) : (line_index += 1) {
            if (self.draw_target.use_ansi) {
                try writer.writeAll("\x1b[2K");
            }

            if (visible_index < visible_count) {
                const progress_ptr = self.nthVisible(visible_index);
                try progress_ptr.writeSnapshotAt(
                    writer,
                    now_ms,
                    self.draw_target.width_columns,
                    self.draw_target.use_ansi,
                );
                progress_ptr.last_render_at_ms = now_ms;
                visible_index += 1;
            }

            if (line_index + 1 < line_count) {
                try writer.writeAll("\n");
            }
        }

        if (self.draw_target.use_ansi and line_count > visible_count and visible_count > 0) {
            try writer.writeAll("\r");
            try writer.print("\x1b[{d}A", .{line_count - visible_count});
        }

        self.last_render_at_ms = now_ms;
        self.rendered_line_count = visible_count;
    }

    fn writeSnapshotAt(
        self: *MultiProgress,
        writer: *std.Io.Writer,
        now_ms: u64,
        width_columns: ?u16,
        use_ansi: bool,
    ) !void {
        var first_line = true;
        for (self.items.items) |progress_ptr| {
            if (progress_ptr.state.finished and progress_ptr.state.clear_on_finish) {
                continue;
            }

            if (!first_line) {
                try writer.writeAll("\n");
            }
            try progress_ptr.writeSnapshotAt(writer, now_ms, width_columns, use_ansi);
            first_line = false;
        }
    }

    fn visibleCount(self: *MultiProgress) u32 {
        var count: u32 = 0;
        for (self.items.items) |progress_ptr| {
            if (progress_ptr.state.finished and progress_ptr.state.clear_on_finish) {
                continue;
            }
            count += 1;
        }
        return count;
    }

    fn nthVisible(
        self: *MultiProgress,
        visible_index: u32,
    ) *Progress {
        var current_visible_index: u32 = 0;
        for (self.items.items) |progress_ptr| {
            if (progress_ptr.state.finished and progress_ptr.state.clear_on_finish) {
                continue;
            }
            if (current_visible_index == visible_index) {
                return progress_ptr;
            }
            current_visible_index += 1;
        }
        unreachable;
    }

    fn shouldRenderAt(
        self: *MultiProgress,
        now_ms: u64,
    ) bool {
        if (self.last_render_at_ms) |last_render_at_ms| {
            const elapsed_ms = now_ms - last_render_at_ms;
            return elapsed_ms >= self.draw_target.refresh_interval_ms;
        }
        return true;
    }
};

fn setText(
    gpa: std.mem.Allocator,
    text: *std.ArrayList(u8),
    value: []const u8,
) !void {
    text.clearRetainingCapacity();
    try text.appendSlice(gpa, value);
}

fn clampPosition(
    position: u64,
    total: ?u64,
) u64 {
    if (total) |total_value| {
        if (position > total_value) {
            return total_value;
        }
    }
    return position;
}

fn appendToken(
    arena: std.mem.Allocator,
    list: *std.ArrayList(u8),
    token: []const u8,
) !void {
    if (token.len == 0) {
        return;
    }

    if (list.items.len > 0) {
        try list.append(arena, ' ');
    }
    try list.appendSlice(arena, token);
}

fn elapsedSeconds(
    started_at_ms: u64,
    now_ms: u64,
) f64 {
    if (now_ms <= started_at_ms) {
        return 0;
    }
    const elapsed_ms = now_ms - started_at_ms;
    return @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
}

fn calculateMessageLimit(
    width_columns: ?u16,
    fixed_width: usize,
) usize {
    const width = width_columns orelse return std.math.maxInt(usize);
    const width_usize: usize = width;
    if (width_usize <= fixed_width) {
        return 0;
    }
    if (width_usize == fixed_width + 1) {
        return 0;
    }
    return width_usize - fixed_width - 1;
}

fn truncateText(
    arena: std.mem.Allocator,
    text: []const u8,
    max_width: usize,
) ![]const u8 {
    if (max_width == 0) {
        return "";
    }
    if (text.len <= max_width) {
        return text;
    }
    if (max_width <= ellipsis.len) {
        return arena.dupe(u8, text[0..max_width]);
    }
    return std.fmt.allocPrint(
        arena,
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
    if (text.len == 0) {
        return;
    }
    if (wrote_segment.*) {
        try writer.writeAll(" ");
    }
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
        try style.writeString(writer, text);
    } else {
        try writer.writeAll(text);
    }
}

fn formatCount(
    arena: std.mem.Allocator,
    unit: Style.Unit,
    value: u64,
) ![]const u8 {
    return switch (unit) {
        .items => std.fmt.allocPrint(arena, "{d}", .{value}),
        .bytes => formatBytes(arena, value),
    };
}

fn formatBytes(
    arena: std.mem.Allocator,
    value: u64,
) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value_f64: f64 = @floatFromInt(value);
    var unit_index: usize = 0;

    while (value_f64 >= 1024.0 and unit_index < units.len - 1) {
        value_f64 /= 1024.0;
        unit_index += 1;
    }

    return std.fmt.allocPrint(
        arena,
        "{d:.1} {s}",
        .{ value_f64, units[unit_index] },
    );
}

fn formatDurationSeconds(
    buffer: []u8,
    seconds: f64,
) []const u8 {
    const total_seconds = @as(u64, @intFromFloat(@max(seconds, 0)));
    const hours = total_seconds / 3600;
    const minutes = (total_seconds % 3600) / 60;
    const secs = total_seconds % 60;

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

test "bar snapshot includes percent and message" {
    var progress = try Progress.bar(std.testing.allocator, .{
        .total = 100,
        .draw_target = DrawTarget.fromFile(std.fs.File.stdout(), .{
            .hidden = false,
            .use_ansi = false,
            .width_columns = 120,
        }),
        .message = "downloading",
    });
    defer progress.deinit();

    progress.setPosition(25);

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();

    try progress.writeSnapshotAt(
        &allocating.writer,
        progress.state.started_at_ms + 2000,
        120,
        false,
    );
    try std.testing.expectEqualStrings(
        "[=====>--------------]  25.0% 25/100 12/s ETA 0:06 downloading",
        allocating.written(),
    );
}

test "spinner snapshot shows elapsed and message" {
    var progress = try Progress.spinner(std.testing.allocator, .{
        .draw_target = DrawTarget.fromFile(std.fs.File.stdout(), .{
            .hidden = false,
            .use_ansi = false,
            .width_columns = 120,
        }),
        .message = "waiting",
    });
    defer progress.deinit();

    progress.tick();
    progress.tick();

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();

    try progress.writeSnapshotAt(
        &allocating.writer,
        progress.state.started_at_ms + 3500,
        120,
        false,
    );
    try std.testing.expectEqualStrings("| elapsed 0:03 waiting", allocating.written());
}

test "message truncates to target width" {
    var progress = try Progress.bar(std.testing.allocator, .{
        .total = 10,
        .draw_target = DrawTarget.fromFile(std.fs.File.stdout(), .{
            .hidden = false,
            .use_ansi = false,
            .width_columns = 32,
        }),
        .message = "this-message-is-too-long",
    });
    defer progress.deinit();

    progress.setPosition(5);

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();

    try progress.writeSnapshotAt(
        &allocating.writer,
        progress.state.started_at_ms + 1000,
        32,
        false,
    );
    try std.testing.expectEqualStrings(
        "[==========>---------]  50.0% 5/10 5/s ETA 0:01",
        allocating.written(),
    );
}

test "render throttled skips recent redraw" {
    var progress = try Progress.bar(std.testing.allocator, .{
        .total = 10,
        .draw_target = DrawTarget.fromFile(std.fs.File.stdout(), .{
            .hidden = false,
            .use_ansi = false,
            .refresh_interval_ms = 100,
        }),
    });
    defer progress.deinit();

    const started_at_ms = progress.state.started_at_ms;
    progress.last_render_at_ms = started_at_ms + 90;

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();

    try progress.renderToWriterAt(&allocating.writer, started_at_ms + 100, .{
        .force = false,
        .interactive = false,
        .width_columns = 120,
        .hidden = false,
        .append_newline = false,
    });
    try std.testing.expectEqualStrings("", allocating.written());
}

test "finish and clear emits clear sequence when interactive" {
    var progress = try Progress.bar(std.testing.allocator, .{
        .total = 10,
        .draw_target = DrawTarget.fromFile(std.fs.File.stdout(), .{
            .hidden = false,
            .use_ansi = true,
        }),
    });
    defer progress.deinit();

    progress.state.finished = true;
    progress.state.clear_on_finish = true;

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();

    try progress.renderToWriterAt(&allocating.writer, progress.state.started_at_ms + 1, .{
        .force = true,
        .interactive = true,
        .width_columns = 120,
        .hidden = false,
        .append_newline = false,
    });
    try std.testing.expectEqualStrings("\r\x1b[2K", allocating.written());
}

test "multi progress snapshot joins visible entries" {
    var multi = MultiProgress.init(std.testing.allocator, .{
        .draw_target = DrawTarget.fromFile(std.fs.File.stdout(), .{
            .hidden = false,
            .use_ansi = false,
            .width_columns = 120,
        }),
    });
    defer multi.deinit();

    const bar = try multi.addBar(.{
        .total = 100,
        .message = "bar",
    });
    const spinner = try multi.addSpinner(.{
        .message = "spin",
    });
    bar.setPosition(50);
    spinner.tick();

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();

    try multi.writeSnapshotAt(
        &allocating.writer,
        bar.state.started_at_ms + 2000,
        120,
        false,
    );
    try std.testing.expectEqualStrings(
        "[==========>---------]  50.0% 50/100 25/s ETA 0:02 bar\n\\ elapsed 0:02 spin",
        allocating.written(),
    );
}

test "multi progress remove deallocates item" {
    var multi = MultiProgress.init(std.testing.allocator, .{
        .draw_target = DrawTarget.fromFile(std.fs.File.stdout(), .{
            .hidden = false,
            .use_ansi = false,
        }),
    });
    defer multi.deinit();

    const spinner = try multi.addSpinner(.{});
    try std.testing.expect(multi.remove(spinner));
    try std.testing.expectEqual(@as(usize, 0), multi.items.items.len);
}

test "progress writer advances position" {
    const BufferWriter = struct {
        total_written: usize = 0,

        fn write(self: *@This(), bytes: []const u8) !usize {
            self.total_written += bytes.len;
            return bytes.len;
        }

        fn writeAll(self: *@This(), bytes: []const u8) !void {
            self.total_written += bytes.len;
        }
    };

    var progress = try Progress.bar(std.testing.allocator, .{
        .total = 100,
        .draw_target = DrawTarget.fromFile(std.fs.File.stdout(), .{
            .hidden = true,
        }),
    });
    defer progress.deinit();

    var buffer_writer = BufferWriter{};
    var progress_writer = progress.wrapWriter(&buffer_writer);
    try progress_writer.writeAll("hello");
    try std.testing.expectEqual(@as(u64, 5), progress.state.position);
    try std.testing.expectEqual(@as(usize, 5), buffer_writer.total_written);
}

test "progress reader advances position" {
    const BufferReader = struct {
        content: []const u8,
        index: usize = 0,

        fn read(self: *@This(), bytes: []u8) !usize {
            const remaining = self.content.len - self.index;
            if (remaining == 0) {
                return 0;
            }

            const count = @min(bytes.len, remaining);
            @memcpy(bytes[0..count], self.content[self.index .. self.index + count]);
            self.index += count;
            return count;
        }
    };

    var progress = try Progress.bar(std.testing.allocator, .{
        .total = 100,
        .draw_target = DrawTarget.fromFile(std.fs.File.stdout(), .{
            .hidden = true,
        }),
    });
    defer progress.deinit();

    var buffer_reader = BufferReader{
        .content = "abcdef",
    };
    var progress_reader = progress.wrapReader(&buffer_reader);
    var bytes: [4]u8 = undefined;
    const read_count = try progress_reader.read(&bytes);
    try std.testing.expectEqual(@as(usize, 4), read_count);
    try std.testing.expectEqual(@as(u64, 4), progress.state.position);
}
