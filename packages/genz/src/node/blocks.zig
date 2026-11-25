const std = @import("std");
const zx = @import("zx");
const node = @import("../node.zig");
const Storage = @import("storage.zig");
const Declarations = @import("stored.zig").Declarations;
const generated = @import("genz_options").generated_analysis;
const Pair = packed struct(u64) { count: u32, start: u32 };
const Layout = struct { start: u64, count: u64, append: bool };
pub const Sequence = Spans(node.Block, "statements");
pub const DeclarationSpans = Spans(Declarations, "declaration_rows");

/// Collect committed row spans in output order.
fn Spans(comptime Span: type, comptime field: []const u8) type {
    return struct {
        const Self = @This();
        storage: *Storage,
        scratch: std.mem.Allocator,
        parts: if (generated) std.ArrayList(u64) else std.MultiArrayList(Span) = .empty,
        last: if (generated) u64 else Span = if (generated) 0 else .{ .start = 0, .len = 0 },
        pub fn deinit(self: *Self) void {
            self.parts.deinit(self.scratch);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            if (generated) {
                self.parts.clearRetainingCapacity();

                self.last = 0;
            } else {
                self.parts.shrinkRetainingCapacity(0);

                self.last = .{ .start = 0, .len = 0 };
            }
        }
        pub fn append(self: *Self, span: Span) std.mem.Allocator.Error!void {
            if (generated) {
                const entry = @import("generated_node_span_append");

                const input: std.meta.Child(entry.Input) = .{
                    .parts = @ptrCast(&self.parts),
                    .allocator = @ptrCast(&self.scratch),
                    .last = self.last,
                    .span = @bitCast(Pair{ .count = span.len, .start = span.start }),
                };

                var fixed = std.heap.FixedBufferAllocator.init(&.{});

                self.last = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch |err| return failure(err);

                return;
            }

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
        pub fn extend(self: *Self, suffix: *const Self) std.mem.Allocator.Error!void {
            const entry = @import("generated_node_span_extend");
            const checkpoint = self.parts.items.len;

            const input: std.meta.Child(entry.Input) = .{
                .parts = @ptrCast(&self.parts),
                .allocator = @ptrCast(&self.scratch),
                .last = self.last,
                .suffix = suffix.parts.items,
                .tail = suffix.last,
            };

            errdefer self.parts.shrinkRetainingCapacity(checkpoint);

            var fixed = std.heap.FixedBufferAllocator.init(&.{});

            self.last = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch |err| return failure(err);
        }
        pub fn finish(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!Span {
            return self.collectSpan(allocator, true);
        }
        pub fn block(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!Span {
            return self.collectSpan(allocator, false);
        }
        fn collectSpan(self: *Self, allocator: std.mem.Allocator, comptime at_tail: bool) std.mem.Allocator.Error!Span {
            const rows = &@field(self.storage, field);

            if (generated) return collectSource(Span, allocator, rows, &.{}, &.{}, self.parts.items, self.last, at_tail);

            if (self.parts.len == 0) {
                if (!at_tail) return self.last;
                if (self.last.len == 0) return .{ .start = @intCast(rows.tags.items.len), .len = 0 };
                if (self.last.start + self.last.len == rows.tags.items.len) return self.last;

                return collectSeed(Span, allocator, rows, &.{self.last.start}, &.{self.last.len}, true);
            }

            try self.parts.append(self.scratch, self.last);

            defer self.parts.shrinkRetainingCapacity(self.parts.len - 1);

            return collectSeed(Span, allocator, rows, self.parts.items(.start), self.parts.items(.len), at_tail);
        }
    };
}

/// The supplied spans refer to previously committed statements.
pub fn join(allocator: std.mem.Allocator, storage: *Storage, starts: []const u32, counts: []const u32) std.mem.Allocator.Error!node.Block {
    return if (generated)
        collectSource(node.Block, allocator, &storage.statements, starts, counts, &.{}, 0, false)
    else
        collectSeed(node.Block, allocator, &storage.statements, starts, counts, false);
}

pub fn joinStatementSpans(allocator: std.mem.Allocator, storage: *Storage, spans: []const u64, at_tail: bool) std.mem.Allocator.Error!node.Block {
    return collectSource(node.Block, allocator, &storage.statements, &.{}, &.{}, spans, 0, at_tail);
}

pub fn joinDeclarations(allocator: std.mem.Allocator, storage: *Storage, starts: []const u32, counts: []const u32) std.mem.Allocator.Error!Declarations {
    return collectSource(Declarations, allocator, &storage.declaration_rows, starts, counts, &.{}, 0, false);
}

/// Publish a block at the end of the statement table so a caller can append to it.
pub fn tail(allocator: std.mem.Allocator, storage: *Storage, starts: []const u32, counts: []const u32) std.mem.Allocator.Error!node.Block {
    return if (generated)
        collectSource(node.Block, allocator, &storage.statements, starts, counts, &.{}, 0, true)
    else
        collectSeed(node.Block, allocator, &storage.statements, starts, counts, true);
}

pub fn appendAtTail(allocator: std.mem.Allocator, storage: *Storage, span: node.Block) std.mem.Allocator.Error!void {
    if (span.len == 0) return;

    _ = try tail(allocator, storage, &.{span.start}, &.{span.len});
}

fn collectSource(comptime Span: type, allocator: std.mem.Allocator, rows: anytype, starts: []const u32, counts: []const u32, parts: []const u64, last: u64, at_tail: bool) std.mem.Allocator.Error!Span {
    std.debug.assert(starts.len == counts.len);

    const entry = @import("generated_node_block_build");
    const lengths: zx.memory.ColumnLengths = &.{ &rows.tags.items.len, &rows.offsets.items.len };
    var views: @import("headers.zig").Views = .{};
    var input = views.bind(std.meta.Child(entry.Input), &allocator, rows, &lengths);
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    input.end = rows.tags.items.len;
    input.starts = starts;
    input.counts = counts;
    input.parts = parts;
    input.last = last;
    input.at_tail = at_tail;

    const layout = zx.columns.invoke(entry.executeValue, fixed.allocator(), @as(*const @TypeOf(input), &input)) catch |err| return failure(err);

    return .{ .start = @intCast(layout.start), .len = @intCast(layout.count) };
}

fn collectSeed(comptime Span: type, allocator: std.mem.Allocator, rows: anytype, starts: []const u32, counts: []const u32, at_tail: bool) std.mem.Allocator.Error!Span {
    std.debug.assert(starts.len == counts.len);

    const start = rows.tags.items.len;
    const layout = measureSeed(starts, counts, start, at_tail);

    if (!layout.append) return .{ .start = @intCast(layout.start), .len = @intCast(layout.count) };
    if (layout.count > std.math.maxInt(u32) - start) return error.OutOfMemory;

    const length: usize = @intCast(layout.count);

    try rows.tags.ensureUnusedCapacity(allocator, length);
    try rows.offsets.ensureUnusedCapacity(allocator, length);

    const tags = rows.tags.unusedCapacitySlice()[0..length];
    const offsets = rows.offsets.unusedCapacitySlice()[0..length];
    var target: usize = 0;

    for (starts, counts) |first, count| {
        @memcpy(tags[target..][0..count], rows.tags.items[first..][0..count]);
        @memcpy(offsets[target..][0..count], rows.offsets.items[first..][0..count]);

        target += count;
    }

    rows.tags.items.len += length;
    rows.offsets.items.len += length;

    return .{ .start = @intCast(start), .len = @intCast(length) };
}

fn measureSeed(starts: []const u32, counts: []const u32, end: usize, at_tail: bool) Layout {
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

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
