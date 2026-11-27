const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const generated = @import("rx_options").generated_graph;
const Self = @This();

fragments: []const rx.ast.Node,
offsets: []const u64,
fields: []const *const rx.ast.Node,
expressions: []const []const u8,
starts: []const u32,
next: []const ?u32,
names: []const []const u8,
ends: []const u64,
text: []const u8,
pub fn build(allocator: std.mem.Allocator, store: rx.ast.Node, groups: ?rx.store.Groups) std.mem.Allocator.Error!Self {
    const grouping = groups orelse try rx.store.groupSeed(allocator, store);
    const fragments = store.children[grouping.first..];
    const offsets = grouping.offsets orelse try allocator.dupe(u64, &.{ 0, fragments[0].children.len });
    const count: usize = @intCast(offsets[fragments.len]);
    const fields = try allocator.alloc(*const rx.ast.Node, count);

    const columns: Columns = if (comptime generated)
        try source(allocator, fragments, offsets, fields)
    else
        try @import("layout/seed.zig").plan(allocator, fragments, offsets, fields);

    return .{
        .fragments = fragments,
        .offsets = offsets,
        .fields = fields,
        .expressions = columns.expressions,
        .starts = grouping.starts,
        .next = grouping.next,
        .names = columns.names,
        .ends = columns.ends,
        .text = columns.text,
    };
}

pub const Columns = struct {
    expressions: []const []const u8,
    names: []const []const u8,
    ends: []const u64,
    text: []const u8,
};

fn source(allocator: std.mem.Allocator, fragments: []const rx.ast.Node, offsets: []const u64, fields: []*const rx.ast.Node) std.mem.Allocator.Error!Columns {
    const rule = @import("generated_rx_store_layout");
    const Input = std.meta.Child(rule.Input);
    const layout = comptime rx.astLayout(std.meta.Child(@FieldType(Input, "layout")));

    const input: Input = .{
        .fragments = std.mem.sliceAsBytes(fragments),
        .offsets = offsets,
        .layout = &layout,
        .resource = @ptrCast(&allocator),
    };

    const planned = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    for (planned.fields, fields) |ref, *slot| {
        slot.* = &fragments[@intCast(ref.object)].children[@intCast(ref.row)];
    }

    return .{ .expressions = planned.expressions, .names = planned.names, .ends = planned.ends, .text = planned.text };
}

pub fn typeStart(self: Self, index: usize) usize {
    return self.typeEnd(index) - self.expressions[index].len;
}

pub fn typeEnd(self: Self, index: usize) usize {
    return @as(usize, @intCast(self.ends[index])) - 1;
}

pub fn nameStart(self: Self, index: usize) usize {
    const base: usize = if (index == 0) 0 else @intCast(self.ends[index - 1]);

    return base + "export type ".len;
}
