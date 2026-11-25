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
    const preparation = @import("generated_prepare_iteration_types");
    const Prepare = std.meta.Child(preparation.Input);
    const PlanInput = std.meta.Child(@FieldType(Prepare, "source"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(PlanInput, "types")), lowering.program.types);
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

    const temporary = buffered.allocator();
    var columns: @import("resources.zig").Columns = .{};

    const prepare: Prepare = .{
        .source = &request,
        .buffers = &columns.bind(std.meta.Child(@FieldType(Prepare, "buffers")), self, false),
    };

    const plan = (preparation.executeIn(temporary, &prepare) catch |err|
        return @import("../construction/publication.zig").failure(err)) orelse return lowering.typeExpr(id);

    const emitter = @import("generated_iteration_types_emit");
    const EmitInput = std.meta.Child(emitter.Input);

    const input: EmitInput = .{
        .types = zx.columns.pointer(@FieldType(EmitInput, "types"), &types),
        .plan = zx.columns.pointer(@FieldType(EmitInput, "plan"), plan),
        .prepared = columns.layouts,
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
