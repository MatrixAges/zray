const std = @import("std");
const zx = @import("zx");
const node = @import("../node.zig");
const Storage = @import("storage.zig");
const generated = @import("genz_options").generated_analysis;
const Layout = struct { start: u64, count: u64, append: bool };
pub const Sequence = Spans(node.Block, "statements");
pub const DeclarationSpans = Spans(@import("stored.zig").Declarations, "declaration_rows");

/// Collect committed row spans in output order.
fn Spans(comptime Span: type, comptime field: []const u8) type {
    return struct {
        const Self = @This();
        storage: *Storage,
        scratch: std.mem.Allocator,
        parts: std.MultiArrayList(Span) = .empty,
        last: Span = .{ .start = 0, .len = 0 },
        pub fn deinit(self: *Self) void {
            self.parts.deinit(self.scratch);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.parts.shrinkRetainingCapacity(0);

            self.last = .{ .start = 0, .len = 0 };
        }
        pub fn append(self: *Self, span: Span) std.mem.Allocator.Error!void {
            if (span.len == 0) return;

            if (self.last.len == 0) {
                self.last = span;
            } else if (self.last.start + self.last.len == span.start) {
                self.last.len += span.len;
            } else {
                try self.parts.append(self.scratch, self.last);

                self.last = span;
            }
        }
        pub fn finish(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!Span {
            return self.collectSpan(allocator, true);
        }
        pub fn block(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!Span {
            return self.collectSpan(allocator, false);
        }
        fn collectSpan(self: *Self, allocator: std.mem.Allocator, comptime at_tail: bool) std.mem.Allocator.Error!Span {
            if (self.parts.len == 0) {
                if (!at_tail) return self.last;
                if (self.last.len == 0) return .{ .start = @intCast(@field(self.storage, field).tags.items.len), .len = 0 };
                if (self.last.start + self.last.len == @field(self.storage, field).tags.items.len) return self.last;

                return collect(Span, allocator, &@field(self.storage, field), &.{self.last.start}, &.{self.last.len}, true);
            }

            try self.parts.append(self.scratch, self.last);

            defer self.parts.shrinkRetainingCapacity(self.parts.len - 1);

            return collect(Span, allocator, &@field(self.storage, field), self.parts.items(.start), self.parts.items(.len), at_tail);
        }
    };
}

/// The supplied spans refer to previously committed statements.
pub fn join(allocator: std.mem.Allocator, storage: *Storage, starts: []const u32, counts: []const u32) std.mem.Allocator.Error!node.Block {
    return collect(node.Block, allocator, &storage.statements, starts, counts, false);
}

/// Publish a block at the end of the statement table so a caller can append to it.
pub fn tail(allocator: std.mem.Allocator, storage: *Storage, starts: []const u32, counts: []const u32) std.mem.Allocator.Error!node.Block {
    return collect(node.Block, allocator, &storage.statements, starts, counts, true);
}

fn collect(comptime Span: type, allocator: std.mem.Allocator, rows: anytype, starts: []const u32, counts: []const u32, comptime at_tail: bool) std.mem.Allocator.Error!Span {
    std.debug.assert(starts.len == counts.len);

    const start = rows.tags.items.len;
    const layout = measure(starts, counts, start, at_tail);

    if (!layout.append) return .{ .start = @intCast(layout.start), .len = @intCast(layout.count) };
    if (layout.count > std.math.maxInt(u32) - start) return error.OutOfMemory;

    const length: usize = @intCast(layout.count);

    try rows.tags.ensureUnusedCapacity(allocator, length);
    try rows.offsets.ensureUnusedCapacity(allocator, length);

    const tags = rows.tags.unusedCapacitySlice()[0..length];
    const offsets = rows.offsets.unusedCapacitySlice()[0..length];

    if (generated) {
        comptime std.debug.assert(@sizeOf(std.meta.Child(@TypeOf(rows.tags.items))) == 1);

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

fn measure(starts: []const u32, counts: []const u32, end: usize, comptime at_tail: bool) Layout {
    if (generated) {
        const entry = @import("generated_node_block_layout");
        const input: std.meta.Child(entry.Input) = .{ .starts = starts, .counts = counts, .end = end, .at_tail = at_tail };
        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        return zx.columns.view(Layout, zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch unreachable);
    }

    var first: u64 = 0;
    var length: u64 = 0;
    var contiguous = true;

    for (starts, counts) |start, count| {
        if (count == 0) continue;

        if (length == 0) {
            first = start;
        } else if (start != first + length) {
            contiguous = false;
        }

        length += count;
    }

    if (length == 0) return .{ .start = if (at_tail) end else 0, .count = 0, .append = false };

    const borrow = contiguous and (!at_tail or first + length == end);

    return .{ .start = if (borrow) first else end, .count = length, .append = !borrow };
}
