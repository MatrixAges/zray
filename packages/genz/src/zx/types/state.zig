const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const generated = @import("generated_state_types");

pub fn build(self: *Lower, declarations: ?*@import("../../node/declarations.zig").Output, exported: bool) Lower.Error!void {
    const Input = std.meta.Child(generated.Input);
    const Output = std.meta.Child(@FieldType(std.meta.Child(generated.Output), "types"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), self.program.types);
    const allocator = self.allocator;

    const input: Input = .{
        .types = &types,
        .selected = self.state_plan.selected,
        .element_storage = self.state_plan.element_storage,
        .borrowed = self.state_plan.borrowed,
        .keys = std.mem.sliceAsBytes(self.state_plan.keys),
        .names = self.type_names,
        .abi_types = view.slice(@FieldType(Input, "abi_types"), @as([]const node.ExpressionId, self.abi_types)),
        .abi_layouts = view.slice(@FieldType(Input, "abi_layouts"), @as([]const node.ExpressionId, self.abi_layouts)),
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .exported = exported,
    };

    const result = @import("zx").columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const output = result.types;

    if (!output.valid) return error.OutOfMemory;
    try @import("import.zig").append(self, declarations, Output, output, result.fields, .borrowed);

    self.state_types = try copyIds(allocator, output.values);
    self.state_layouts = try copyIds(allocator, output.layouts);
    self.view_types = try copyIds(allocator, output.views);
}

fn copyIds(allocator: std.mem.Allocator, source: []const u32) std.mem.Allocator.Error![]node.ExpressionId {
    const result = try allocator.alloc(node.ExpressionId, source.len);

    for (result, source) |*target, item| target.* = @fromBackingInt(item);

    return result;
}
