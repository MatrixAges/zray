const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");

pub fn lower(context: *Context, id: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    const self = context.lowering;
    const root_layout = try @import("types.zig").get(context, id);
    const preparation = @import("generated_prepare_iteration_input");
    const Prepare = std.meta.Child(preparation.Input);
    const PlanInput = std.meta.Child(@FieldType(Prepare, "source"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(PlanInput, "types")), self.program.types);

    const request: PlanInput = .{
        .types = &types,
        .layouts = zx.columns.slice(@FieldType(PlanInput, "layouts"), self.layout_types),
        .root = @backingInt(id),
        .inline_lists = context.inline_lists,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = buffered.allocator();
    var columns: @import("resources.zig").Columns = .{};

    const prepare: Prepare = .{
        .source = &request,
        .root = @backingInt(root_layout),
        .buffers = &columns.bind(std.meta.Child(@FieldType(Prepare, "buffers")), context, true),
    };

    const serial = self.serial;
    const declarations = context.declarations.last;

    const plan = (preparation.executeIn(temporary, &prepare) catch |err|
        return @import("../construction/publication.zig").failure(err)) orelse return value;

    std.debug.assert(serial == self.serial and std.meta.eql(declarations, context.declarations.last));

    const emitter = @import("generated_conversion_emit");
    const Input = std.meta.Child(emitter.Input);

    const input: Input = .{
        .plan = zx.columns.pointer(@FieldType(Input, "plan"), plan),
        .layouts = columns.layouts,
        .elements = columns.operands,
        .value = @backingInt(value),
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const output = emitter.executeIn(buffered.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    try @import("publication.zig").write(self, .Input, .{ .body = context.declarations }, output);

    return @fromBackingInt(output.root);
}
