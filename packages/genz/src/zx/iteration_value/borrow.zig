const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");

pub fn lower(self: *Context, body: *Context.Statements, id: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("borrow_seed.zig").lower(self, body, id, value);

    const lowering = self.lowering;
    const root_layout = try lowering.layoutExpr(id);
    const preparation = @import("generated_prepare_iteration_borrow");
    const Prepare = std.meta.Child(preparation.Input);
    const Input = std.meta.Child(@FieldType(Prepare, "source"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), lowering.program.types);

    const request: Input = .{
        .types = &types,
        .layouts = zx.columns.slice(@FieldType(Input, "layouts"), lowering.layout_types),
        .root = @backingInt(id),
    };

    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = buffered.allocator();
    var columns: @import("resources.zig").Columns = .{};

    const prepare: Prepare = .{
        .source = &request,
        .root = @backingInt(root_layout),
        .buffers = &columns.bind(std.meta.Child(@FieldType(Prepare, "buffers")), self, false),
    };

    const plan = (preparation.executeIn(temporary, &prepare) catch |err|
        return @import("../construction/publication.zig").failure(err)) orelse return value;

    const emitter = @import("generated_iteration_borrow_emit");
    const Call = std.meta.Child(emitter.Input);
    const EmitInput = std.meta.Child(@FieldType(Call, "request"));

    const input: EmitInput = .{
        .plan = zx.columns.pointer(@FieldType(EmitInput, "plan"), plan),
        .layouts = columns.layouts,
        .value = @backingInt(value),
        .expression_base = @intCast(lowering.builder.nodes.expressions.tags.items.len),
        .field_base = @intCast(lowering.builder.nodes.field_columns.count()),
        .serial = lowering.serial,
    };

    const call: Call = .{
        .frame = @ptrCast(lowering),
        .writer = @ptrCast(lowering),
        .body = @ptrCast(body),
        .request = &input,
    };

    const root = emitter.executeIn(buffered.allocator(), &call) catch |err|
        return @import("../construction/publication.zig").failure(err);

    return @fromBackingInt(root);
}
