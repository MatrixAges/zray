const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Selection = @FieldType(ir.StatementRow, "switch_stmt");
const Self = @This();

selection: Selection,
name: []const u8,
subject: node.ExpressionId,
reference: node.ExpressionId,
previous: ?node.ExpressionId,
scratch: std.heap.ArenaAllocator,
inline_memory: [512]u8 = undefined,
memory: std.heap.BufferFirstAllocator = undefined,
fallback: ?node.Block = null,
selected: bool = false,
active: bool = false,
starts: []u32 = &.{},
counts: []u32 = &.{},
comparisons: []u32 = &.{},
literals: []?u32 = &.{},
pub fn enter(
    self: *Self,
    lowering: *Lower,
    selection: Selection,
    name: []const u8,
    subject: node.ExpressionId,
    reference: node.ExpressionId,
) Lower.Error!void {
    const previous = lowering.cache.get(selection.subject);

    try lowering.cache.put(lowering.allocator, selection.subject, reference);

    self.* = .{
        .selection = selection,
        .name = name,
        .subject = subject,
        .reference = reference,
        .previous = previous,
        .scratch = .init(lowering.workspace),
        .active = true,
    };

    self.memory = .init(&self.inline_memory, self.scratch.allocator());
}

pub fn resolve(self: *Self, named: usize, selected: bool) Lower.Error!void {
    const allocator = self.memory.allocator();

    self.selected = selected;
    self.starts = try allocator.alloc(u32, named);
    self.counts = try allocator.alloc(u32, named);
    self.comparisons = try allocator.alloc(u32, named);
    self.literals = try allocator.alloc(?u32, named);
}

pub fn saveCase(self: *Self, index: usize, child: node.Block, comparison: u32, literal: ?u32) void {
    self.starts[index] = child.start;
    self.counts[index] = child.len;
    self.comparisons[index] = comparison;
    self.literals[index] = literal;
}

pub fn finish(self: *Self, lowering: *Lower) Lower.Error!node.Block {
    return @import("publish.zig").lower(lowering, self, self.memory.allocator());
}

pub fn leave(self: *Self, lowering: *Lower) void {
    if (!self.active) return;

    self.active = false;

    self.scratch.deinit();
    lowering.cache.restoreEntry(lowering.allocator, self.selection.subject, self.previous);
}
