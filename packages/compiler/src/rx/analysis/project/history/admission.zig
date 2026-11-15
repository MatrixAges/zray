const std = @import("std");
const bytes = @import("zx").bytes;
const Source = @import("frontend").project.Source;
const Graph = @import("../source_graph/model.zig").Graph;
const generated = @import("rx_options").generated_graph;

const SourceChange = if (generated) @import("generated_rx_history_source").Output else enum {
    DifferentPath,
    Unchanged,
    Edited,
};

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

pub fn source(earlier: *const Source, current: *const Source) SourceChange {
    if (comptime generated) {
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return @import("generated_rx_history_source").executeValue(empty.allocator(), &.{
            .earlier_path = earlier.path,
            .current_path = current.path,
            .earlier_source = earlier.source,
            .current_source = current.source,
        }) catch unreachable;
    }

    if (!bytes.equal(earlier.path, current.path)) return .DifferentPath;

    return if (bytes.equal(earlier.source, current.source)) .Unchanged else .Edited;
}

pub fn sameHeader(earlier: []const u8, current: []const u8, body: usize) bool {
    if (comptime generated) {
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return @import("generated_rx_history_header").executeValue(empty.allocator(), &.{
            .earlier = earlier,
            .current = current,
            .body = body,
        }) catch unreachable;
    }

    const shared = std.mem.indexOfDiff(u8, earlier, current) orelse return false;

    return shared > body;
}

pub fn signed(earlier: *const [32]u8, current: *const [32]u8, before: *const Graph, after: *const Graph, rows: []const u64) bool {
    const earlier_paths = before.modules.items(.path)[0..before.sources.zx_count];
    const current_paths = after.modules.items(.path)[0..after.sources.zx_count];

    if (comptime generated and @sizeOf(usize) == @sizeOf(u64) and @alignOf(usize) >= @alignOf(u64)) {
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return @import("generated_rx_history_signatures").executeValue(empty.allocator(), &.{
            .inputs = &.{
                .earlier = earlier,
                .current = current,
                .earlier_count = earlier_paths.len,
                .current_count = current_paths.len,
            },
            .entries = &.{
                .earlier_order = @ptrCast(before.order),
                .earlier_paths = earlier_paths,
                .current_paths = current_paths,
                .current_rows = rows,
            },
        }) catch unreachable;
    }

    if (!sameInputs(earlier, current, earlier_paths.len, current_paths.len)) return false;

    var selected: usize = 0;

    for (before.order) |row| {
        if (row >= earlier_paths.len) continue;
        if (selected == rows.len or !bytes.equal(earlier_paths[row], current_paths[@intCast(rows[selected])])) return false;

        selected += 1;
    }

    return selected == rows.len;
}
