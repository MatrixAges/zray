const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const generated = @import("parser_options").generated_parser;
const seed = @import("module_versions/seed.zig");
pub const Position = struct { previous: u64 };

pub const Plan = struct {
    whole: bool,
    prefix: usize,
    tail: []const Position,
    pub fn at(self: Plan, row: usize) u64 {
        if (row < self.prefix) return row + 1;

        return if (self.tail.len == 0) 0 else self.tail[row - self.prefix].previous;
    }
};

pub fn prepare(allocator: std.mem.Allocator, before: anytype, sources: anytype, previous_packages: ?*const [32]u8, packages: *const [32]u8) !Plan {
    if (comptime !generated) return seed.prepare(allocator, before, sources, previous_packages, packages);

    const rule = @import("generated_input_module_versions");
    const Input = std.meta.Child(rule.Input);
    const Target = std.meta.Child(@FieldType(Input, "target"));
    const previous_paths = memory.borrowReferencedTextColumn("path", before);
    const previous_texts = memory.borrowReferencedTextPath(&.{ "parsed", "xml", "source" }, before);
    const paths = memory.borrowTextColumn("path", sources);
    const texts = memory.borrowTextColumn("source", sources);
    var positions: memory.RowOutput(Position, struct { rows: @FieldType(Target, "rows") }, .{ .rows = &.{"previous"} }) = undefined;

    positions.init();

    const input: Input = .{
        .probe = &.{
            .prior = &.{ .paths = @ptrCast(&previous_paths), .texts = @ptrCast(&previous_texts), .count = before.len },
            .current = &.{ .paths = @ptrCast(&paths), .texts = @ptrCast(&texts), .count = sources.len },
            .before = if (previous_packages) |hash| hash else null,
            .packages = packages,
        },
        .target = &.{ .buffer = @ptrCast(&positions.buffer), .rows = positions.view.rows },
    };

    const result = try zx.columns.invoke(rule.executeValue, allocator, &input);

    return .{ .whole = result.whole, .prefix = @intCast(result.prefix), .tail = positions.rows() };
}

pub const Operation = enum { Publish, Discard, Restore };
pub const Slot = enum { Current, Pending, Previous };
pub const Transition = struct { next: Slot, drop_current: bool, drop_pending: bool, retain: bool };

pub fn transition(operation: Operation, pending: bool, already_current: bool) Transition {
    if (comptime !generated) return seed.transition(operation, pending, already_current);

    const rule = @import("generated_input_module_transition");
    const Input = if (@typeInfo(rule.Input) == .pointer) std.meta.Child(rule.Input) else rule.Input;

    const input: Input = .{
        .operation = @fromBackingInt(@intCast(@backingInt(operation))),
        .pending = pending,
        .already_current = already_current,
    };

    var memory_buffer: [128]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&memory_buffer);
    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    return .{
        .next = @fromBackingInt(@intCast(@backingInt(result.next))),
        .drop_current = result.drop_current,
        .drop_pending = result.drop_pending,
        .retain = result.retain,
    };
}
