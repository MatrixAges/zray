const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");

pub fn get(self: *Context, id: ir.TypeId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("types_seed.zig").get(self, id);
    if (self.types.get(id)) |value| return value;

    const lowering = self.lowering;
    const planner = @import("generated_iteration_types_plan");
    const PlanInput = std.meta.Child(planner.Input);
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(PlanInput, "types")), lowering.program.types);
    const classifier = @import("generated_iteration_type_operation");
    const Classification = std.meta.Child(classifier.Input);
    const classification: Classification = .{ .kind = types.kinds[@backingInt(id)], .inline_lists = self.inline_lists };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const operation = zx.columns.invoke(classifier.executeValue, fixed.allocator(), &classification) catch unreachable;

    if (operation == .Native) return lowering.typeExpr(id);

    const cached = self.types.view(std.meta.Child(@FieldType(PlanInput, "cached")));

    const request: PlanInput = .{
        .types = &types,
        .cached = &cached,
        .root = @backingInt(id),
        .inline_lists = self.inline_lists,
    };

    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const plan = planner.executeIn(buffered.allocator(), &request) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const resources = @import("resources.zig");
    const prepared = try resources.layouts(self, buffered.allocator(), plan.leaves, @fromBackingInt(0), .leaves);
    const emitter = @import("generated_iteration_types_emit");
    const EmitInput = std.meta.Child(emitter.Input);

    const input: EmitInput = .{
        .types = &types,
        .plan = plan,
        .prepared = prepared,
        .expression_base = @intCast(lowering.builder.nodes.expressions.tags.items.len),
        .field_base = @intCast(lowering.builder.nodes.field_columns.count()),
        .serial = lowering.serial,
    };

    const output = emitter.executeIn(buffered.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    try @import("publication.zig").write(lowering, .Types, .{ .context = self, .body = self.declarations }, output);

    return @fromBackingInt(output.root);
}

pub fn element(lowering: *Lower, id: ir.TypeId) Lower.Error!node.ExpressionId {
    if (lowering.iteration_value) |context| if (context.inline_lists and @import("../iteration_layout.zig").represented(lowering, id)) return get(context, id);

    return try lowering.typeExpr(id);
}
