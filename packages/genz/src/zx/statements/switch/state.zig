const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const labels_analysis = @import("../../selection.zig");
const references = @import("references.zig");
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
pub fn enter(self: *Self, lowering: *Lower, selection: Selection) Lower.Error!void {
    const name = try references.name(lowering);
    const subject = try lowering.expr(selection.subject);
    const previous = lowering.cache.get(selection.subject);
    const reference = try references.identifier(lowering, name);

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

pub fn resolve(self: *Self, lowering: *Lower, named: usize) Lower.Error!void {
    const allocator = self.memory.allocator();
    const labels = try allocator.alloc(u32, named);

    try collectLabels(self.selection.cases.values[0..self.selection.cases.len], labels);

    self.selected = try labels_analysis.labels(lowering, self.selection.subject, labels);
    self.starts = try allocator.alloc(u32, named);
    self.counts = try allocator.alloc(u32, named);
    self.comparisons = try allocator.alloc(u32, named);
    self.literals = try allocator.alloc(?u32, named);
}

pub fn resetCase(self: *Self, index: usize) void {
    self.comparisons[index] = 0;
    self.literals[index] = null;
}

pub fn saveCase(self: *Self, index: usize, child: node.Block) void {
    self.starts[index] = child.start;
    self.counts[index] = child.len;
}

pub fn compareCase(self: *Self, lowering: *Lower, index: usize, label: ir.ExprId) Lower.Error!void {
    self.comparisons[index] = @backingInt(try equal(self, lowering, label));
}

pub fn literalCase(self: *Self, lowering: *Lower, index: usize, label: ir.ExprId) Lower.Error!void {
    self.literals[index] = @backingInt(try labels_analysis.literal(lowering, label));
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

fn equal(self: *const Self, lowering: *Lower, label: ir.ExprId) Lower.Error!node.ExpressionId {
    return lowering.binary(.{ .operator = .equal, .left = self.selection.subject, .right = label });
}

fn collectLabels(values: []const ?u32, labels_arg: []u32) Lower.Error!void {
    var labels = labels_arg;
    const entry = @import("generated_switch_labels");
    const input: std.meta.Child(entry.Input) = .{ .values = values, .labels = @ptrCast(&labels) };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };
}
