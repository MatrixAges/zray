const std = @import("std");
const zx = @import("zx");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const Cache = @import("cache.zig");
const generated = @import("generated_shared_state");
const Input = std.meta.Child(generated.Input);
const Mode = @FieldType(std.meta.Child(@FieldType(Input, "request")), "mode");

pub fn build(self: *Lower, index: usize, mode: Mode) Lower.Error!void {
    const Abi = std.meta.Child(@FieldType(Input, "abi"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Abi, "types")), self.program.types);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const abi: Abi = .{
        .types = &types,
        .names = self.type_names,
        .cached = view.slice(@FieldType(Abi, "cached"), @as([]const node.ExpressionId, self.abi_types)),
        .root = @intCast(index),
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
    };

    const input: Input = .{
        .abi = &abi,
        .selected = self.state_plan.selected,
        .borrowed = self.state_plan.borrowed,
        .keys = std.mem.sliceAsBytes(self.state_plan.keys),
        .states = view.slice(@FieldType(Input, "states"), @as([]const node.ExpressionId, self.state_types)),
        .state_layouts = view.slice(@FieldType(Input, "state_layouts"), @as([]const node.ExpressionId, self.state_layouts)),
        .views = view.slice(@FieldType(Input, "views"), @as([]const node.ExpressionId, self.view_types)),
        .abi_layouts = view.slice(@FieldType(Input, "abi_layouts"), @as([]const node.ExpressionId, self.abi_layouts)),
        .request = &.{ .id = @intCast(index), .mode = mode },
    };

    const output = zx.columns.invoke(generated.executeValue, buffered.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const Output = std.meta.Child(generated.Output);

    return Cache.publish(self, Output, output, false);
}
