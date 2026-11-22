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
    const planner = @import("generated_iteration_borrow_plan");
    const Input = std.meta.Child(planner.Input);
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), lowering.program.types);

    const request: Input = .{
        .types = &types,
        .layouts = zx.columns.slice(@FieldType(Input, "layouts"), lowering.layout_types),
        .root = @backingInt(id),
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const operation = zx.columns.invoke(@import("generated_iteration_borrow_operation").executeValue, fixed.allocator(), &request) catch unreachable;

    if (operation == .Value) return value;

    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const plan = planner.executeIn(buffered.allocator(), &request) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const resources = @import("resources.zig");
    const Layouts = @FieldType(std.meta.Child(@import("generated_resolve_iteration_resources").Input), "borrowed");
    const layouts = try resources.layouts(self, buffered.allocator(), plan.types, root_layout, .{ .borrowed = zx.columns.slice(Layouts, plan.kinds) });
    const emitter = @import("generated_iteration_borrow_emit");
    const EmitInput = std.meta.Child(emitter.Input);

    const input: EmitInput = .{
        .plan = plan,
        .layouts = layouts,
        .value = @backingInt(value),
        .expression_base = @intCast(lowering.builder.nodes.expressions.tags.items.len),
        .field_base = @intCast(lowering.builder.nodes.field_columns.count()),
        .serial = lowering.serial,
    };

    const output = emitter.executeIn(buffered.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    const expressions = @import("../../node/view.zig").join(output.expressions.*, output.forms.*);

    @import("../../node/import_rows.zig").append(lowering.allocator, &lowering.builder.nodes.expressions, &expressions) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    _ = @import("../../node/import_fields.zig").appendBorrowingText(lowering.allocator, &lowering.builder.nodes.field_columns, output.fields) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    @import("../../node/import_statements.zig").append(lowering.allocator, body, output.statements) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    lowering.serial = output.serial;

    return @fromBackingInt(output.root);
}
