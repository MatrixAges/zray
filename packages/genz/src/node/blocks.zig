const std = @import("std");
const zx = @import("zx");
const node = @import("../node.zig");
const Storage = @import("storage.zig");
const generated = @import("genz_options").generated_analysis;
const Layout = struct { start: u64, count: u64, contiguous: bool };

/// The supplied spans refer to previously committed statements.
pub fn join(allocator: std.mem.Allocator, storage: *Storage, starts: []const u32, counts: []const u32) std.mem.Allocator.Error!node.Block {
    return collect(allocator, storage, starts, counts, false);
}

/// Publish a block at the end of the statement table so a caller can append to it.
pub fn tail(allocator: std.mem.Allocator, storage: *Storage, starts: []const u32, counts: []const u32) std.mem.Allocator.Error!node.Block {
    return collect(allocator, storage, starts, counts, true);
}

fn collect(allocator: std.mem.Allocator, storage: *Storage, starts: []const u32, counts: []const u32, comptime at_tail: bool) std.mem.Allocator.Error!node.Block {
    std.debug.assert(starts.len == counts.len);

    const rows = &storage.statements;
    const start = rows.tags.items.len;

    const layout: Layout = switch (counts.len) {
        0 => return .{ .start = if (at_tail) @intCast(start) else 0 },
        1 => .{ .start = starts[0], .count = counts[0], .contiguous = true },
        else => measure(starts, counts),
    };

    if (layout.count == 0) return .{ .start = if (at_tail) @intCast(start) else 0 };
    if (layout.contiguous and (!at_tail or layout.start + layout.count == start)) return .{ .start = @intCast(layout.start), .len = @intCast(layout.count) };
    if (layout.count > std.math.maxInt(u32) - start) return error.OutOfMemory;

    const length: usize = @intCast(layout.count);

    try rows.tags.ensureUnusedCapacity(allocator, length);
    try rows.offsets.ensureUnusedCapacity(allocator, length);

    const tags = rows.tags.unusedCapacitySlice()[0..length];
    const offsets = rows.offsets.unusedCapacitySlice()[0..length];

    if (generated) {
        comptime std.debug.assert(@sizeOf(std.meta.Tag(node.Statement)) == 1);

        const entry = @import("generated_node_block_publish");

        const input: std.meta.Child(entry.Input) = .{
            .starts = starts,
            .counts = counts,
            .tags = std.mem.sliceAsBytes(rows.tags.items),
            .offsets = rows.offsets.items,
            .target_tags = @ptrCast(&std.mem.sliceAsBytes(tags)),
            .target_offsets = @ptrCast(&offsets),
        };

        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable;
    } else {
        var target: usize = 0;

        for (starts, counts) |first, count| {
            @memcpy(tags[target..][0..count], rows.tags.items[first..][0..count]);
            @memcpy(offsets[target..][0..count], rows.offsets.items[first..][0..count]);

            target += count;
        }
    }

    rows.tags.items.len += length;
    rows.offsets.items.len += length;

    return .{ .start = @intCast(start), .len = @intCast(length) };
}

fn measure(starts: []const u32, counts: []const u32) Layout {
    if (generated) {
        const entry = @import("generated_node_block_layout");
        const input: std.meta.Child(entry.Input) = .{ .starts = starts, .counts = counts };
        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        return zx.columns.view(Layout, zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable);
    }

    var result: Layout = .{ .start = 0, .count = 0, .contiguous = true };

    for (starts, counts) |start, count| {
        if (count == 0) continue;

        if (result.count == 0) {
            result.start = start;
        } else if (start != result.start + result.count) {
            result.contiguous = false;
        }

        result.count += count;
    }

    return result;
}
