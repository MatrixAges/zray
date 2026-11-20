const std = @import("std");
const zx = @import("zx");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const module = @import("../../node/import_module.zig");
const Lower = @import("../lower.zig");
const Cache = @import("cache.zig");
const generated = @import("generated_shared_state");
const publish = @import("generated_publish_shared_state");
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

    if (!output.valid) return error.OutOfMemory;

    const Output = std.meta.Child(generated.Output);
    const imported = module.append(self.allocator, self.builder.nodes, Output, output);

    imported catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    const Publication = std.meta.Child(publish.Input);
    const Columns = std.meta.Child(@FieldType(Publication, "columns"));
    const target = Cache.borrow(self);
    const tracked = target.touch(Cache.Touched(Columns));
    const columns = target.columns(Columns, &tracked);
    const publication: Publication = .{ .entries = output.entries, .columns = &columns };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(publish.executeValue, fixed.allocator(), &publication) catch unreachable;
}
