const std = @import("std");
const bytes = @import("zx").bytes;
const Source = @import("frontend").project.Source;
const Graph = @import("../source_graph/model.zig").Graph;
const generated = @import("rx_options").generated_graph;
const memory = @import("zx").memory;
const ParseCache = @import("frontend").project.ParseCache;
const History = @import("../history.zig");

pub const SourceColumns = struct {
    paths: memory.TextColumn,
    texts: memory.TextColumn,
    count: usize,
    pub fn init(sources: []const Source) SourceColumns {
        return .{
            .paths = memory.borrowTextColumn("path", sources),
            .texts = memory.borrowTextColumn("source", sources),
            .count = sources.len,
        };
    }

    pub fn view(self: *const SourceColumns, comptime View: type) View {
        return .{ .paths = @ptrCast(&self.paths), .texts = @ptrCast(&self.texts) };
    }
};

pub fn bodies(history: *const History.History, earlier: *const History.Retained, current: []const Source, cache: *ParseCache) std.mem.Allocator.Error!bool {
    const rule = @import("generated_rx_history_body_edits");
    const Input = std.meta.Child(rule.Input);
    const Pair = std.meta.Child(@FieldType(Input, "sources"));
    const View = std.meta.Child(@FieldType(Pair, "earlier"));
    const before = SourceColumns.init(earlier.sources);
    const after = SourceColumns.init(current);
    const earlier_view = before.view(View);
    const current_view = after.view(View);
    const paths = earlier.derived.dependencies.modules.items(.path)[0..earlier.sources.len];
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    var request: Input = .{
        .identity = &.{
            .earlier = &earlier.frame,
            .current = &history.frame,
            .earlier_count = earlier.sources.len,
            .current_count = current.len,
        },
        .sources = &.{
            .earlier = &earlier_view,
            .current = &current_view,
            .earlier_count = earlier.sources.len,
            .current_count = current.len,
        },
        .row = null,
        .opening = null,
    };

    while (true) {
        const next = rule.executeIn(empty.allocator(), &request) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        } orelse return false;

        if (next == current.len) return true;

        const row: usize = @intCast(next);
        const parsed = try cache.getModule(current[row].source, paths[row]);

        request.row = next;
        request.opening = parsed.bodyStart();
    }
}

pub fn sameInputs(earlier: *const [32]u8, current: *const [32]u8, earlier_count: usize, current_count: usize) bool {
    if (comptime generated) {
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return @import("generated_rx_history_inputs").executeValue(empty.allocator(), &.{
            .earlier = earlier,
            .current = current,
            .earlier_count = earlier_count,
            .current_count = current_count,
        }) catch unreachable;
    }

    return earlier_count == current_count and std.mem.eql(u8, earlier, current);
}

pub fn signed(history: *const History.History, earlier: *const History.Retained, sources: []const Source, after: *const Graph, rows: []const u64) bool {
    const before = &earlier.derived.dependencies;
    const earlier_paths = before.modules.items(.path)[0..before.sources.zx_count];
    const current_paths = after.modules.items(.path)[0..after.sources.zx_count];

    if (comptime generated and @sizeOf(usize) == @sizeOf(u64) and @alignOf(usize) >= @alignOf(u64)) {
        const rule = @import("generated_rx_history_signatures");
        const Input = std.meta.Child(rule.Input);
        const Pair = std.meta.Child(@FieldType(Input, "sources"));
        const View = std.meta.Child(@FieldType(Pair, "earlier"));
        const old_sources = SourceColumns.init(earlier.sources);
        const new_sources = SourceColumns.init(sources);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return rule.executeValue(empty.allocator(), &.{
            .inputs = &.{
                .earlier = &earlier.shape,
                .current = &history.shape,
                .earlier_count = earlier_paths.len,
                .current_count = current_paths.len,
            },
            .entries = &.{
                .earlier_order = @ptrCast(before.order),
                .earlier_paths = earlier_paths,
                .current_paths = current_paths,
                .current_rows = rows,
            },
            .sources = &.{
                .earlier = &old_sources.view(View),
                .current = &new_sources.view(View),
                .earlier_count = earlier.sources.len,
                .current_count = sources.len,
            },
        }) catch unreachable;
    }

    if (!sameInputs(&earlier.shape, &history.shape, earlier_paths.len, current_paths.len)) return false;

    var selected: usize = 0;

    for (before.order) |row| {
        if (row >= earlier_paths.len) continue;
        if (selected == rows.len or !bytes.equal(earlier_paths[row], current_paths[@intCast(rows[selected])])) return false;

        selected += 1;
    }

    if (selected != rows.len or earlier.sources.len != sources.len) return false;

    for (earlier.sources, sources) |*old, *new| {
        if (!bytes.equal(old.path, new.path) or !bytes.equal(old.source, new.source)) return false;
    }

    return true;
}
