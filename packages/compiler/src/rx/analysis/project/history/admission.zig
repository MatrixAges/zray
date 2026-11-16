const std = @import("std");
const bytes = @import("zx").bytes;
const Source = @import("frontend").project.Source;
const Graph = @import("../source_graph/model.zig").Graph;
const generated = @import("rx_options").generated_graph;
const memory = @import("zxc_standard").memory;

pub const SourceScan = struct {
    earlier_paths: memory.TextColumn,
    earlier_texts: memory.TextColumn,
    current_paths: memory.TextColumn,
    current_texts: memory.TextColumn,
    count: usize,
    const rule = @import("generated_rx_history_source");

    const Result = @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload;

    pub fn init(earlier: []const Source, current: []const Source) SourceScan {
        std.debug.assert(earlier.len == current.len);

        return .{
            .earlier_paths = memory.borrowTextColumn("path", earlier),
            .earlier_texts = memory.borrowTextColumn("source", earlier),
            .current_paths = memory.borrowTextColumn("path", current),
            .current_texts = memory.borrowTextColumn("source", current),
            .count = current.len,
        };
    }
    pub fn next(self: *const SourceScan, first: usize) Result {
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        return rule.executeValue(empty.allocator(), &.{
            .earlier = &.{ .paths = @ptrCast(&self.earlier_paths), .texts = @ptrCast(&self.earlier_texts) },
            .current = &.{ .paths = @ptrCast(&self.current_paths), .texts = @ptrCast(&self.current_texts) },
            .first = first,
            .end = self.count,
        }) catch unreachable;
    }
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
