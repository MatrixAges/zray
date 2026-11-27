const std = @import("std");
const zx = @import("zx");
const Lower = @import("../lower.zig");
const payloads = @import("../../node/import_payloads.zig");
const Self = @This();

abi_types: []u32,
abi_layouts: []u32,
state_types: []u32,
state_layouts: []u32,
views: []u32,
rows: []u32,
pub fn borrow(lower: *const Lower) Self {
    const scratch = lower.type_scratch;

    return .{
        .abi_types = @ptrCast(lower.abi_types),
        .abi_layouts = @ptrCast(lower.abi_layouts),
        .state_types = @ptrCast(lower.state_types),
        .state_layouts = @ptrCast(lower.state_layouts),
        .views = @ptrCast(lower.view_types),
        .rows = if (scratch) |storage| storage.columns.touched else &.{},
    };
}

pub fn columns(self: *Self, comptime T: type) T {
    return .{
        .abi_types = @ptrCast(&self.abi_types),
        .abi_layouts = @ptrCast(&self.abi_layouts),
        .state_types = @ptrCast(&self.state_types),
        .state_layouts = @ptrCast(&self.state_layouts),
        .views = @ptrCast(&self.views),
        .touched = if (self.rows.len == 0) null else @ptrCast(&self.rows),
    };
}

/// Cached handles refer only to expressions that were committed to the AST.
pub fn publish(lower: *Lower, comptime Output: type, output: anytype, comptime borrow_text: bool) Lower.Error!void {
    if (!output.valid) return error.OutOfMemory;

    const entry = @import("generated_commit_shared_types");
    const Input = std.meta.Child(entry.Input);
    const Columns = std.meta.Child(@FieldType(Input, "columns"));
    const Bound = std.meta.Child(@FieldType(Input, "ast"));
    const Expressions = std.meta.Child(@FieldType(Output, "expressions"));
    const expressions = zx.columns.view(Expressions, output.expressions);
    const target = &lower.builder.nodes.expressions;
    var binding: payloads.Binding(@TypeOf(target), Expressions, .dense) = .{};
    const ast = binding.bind(Bound, &lower.allocator, target, &expressions, true, borrow_text);
    var cache = borrow(lower);
    const rows = cache.columns(Columns);
    const state = @hasField(Output, "entries");

    const input: Input = .{
        .ast = &ast,
        .columns = &rows,
        .abi = if (state) null else &.{ .ids = output.ids, .values = output.values, .layouts = output.layouts },
        .state = if (state) output.entries else null,
        .dirty = if (lower.type_scratch) |storage| storage.dirty else 0,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    const result = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch |err| switch (payloads.failure(err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    switch (result.check) {
        .Valid => {},
        .Invalid => unreachable,
        .Exhausted => return error.OutOfMemory,
    }

    if (lower.type_scratch) |storage| storage.dirty = result.dirty;
}
