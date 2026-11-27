const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");

pub fn lower(context: *Context, id: ir.TypeId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    const self = context.lowering;
    const root_layout = try self.layoutExpr(id);
    const preparation = @import("generated_prepare_iteration_returned");
    const Prepare = std.meta.Child(preparation.Input);
    const SourcePlan = std.meta.Child(@FieldType(Prepare, "source"));
    const PlanInput = std.meta.Child(@FieldType(SourcePlan, "source"));
    const Facts = std.meta.Child(@FieldType(SourcePlan, "facts"));
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

    const facts: Facts = .{
        .active = self.state_active,
        .selected = self.state_plan.selected,
        .borrowed = self.state_plan.borrowed,
    };

    const prepare: Prepare = .{
        .source = &.{ .source = &request, .facts = &facts },
        .root = @backingInt(root_layout),
        .frame = @ptrCast(context),
    };

    const serial = self.serial;
    const declarations = context.declarations.last;
    const storage = self.referenceBatches();

    const prepared = (preparation.executeIn(temporary, &prepare) catch |err|
        return @import("../construction/publication.zig").failure(err)) orelse return value;

    const generated = @import("generated_conversion_output");
    const Call = std.meta.Child(generated.Input);
    const Input = std.meta.Child(@FieldType(Call, "request"));
    const Source = std.meta.Child(@FieldType(Input, "source"));

    std.debug.assert(serial == self.serial and std.meta.eql(declarations, context.declarations.last) and storage == self.referenceBatches());

    const ast = @import("../construction/ast.zig").borrow(std.meta.Child(@FieldType(Input, "ast")), self);

    const source: Source = .{
        .plan = zx.columns.pointer(@FieldType(Source, "plan"), prepared.plan.plan),
        .layouts = prepared.layouts,
        .elements = &.{},
        .value = @backingInt(value),
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const input: Input = .{
        .source = &source,
        .requirements = zx.columns.slice(@FieldType(Input, "requirements"), prepared.plan.requirements),
        .ast = &ast,
        .operands = prepared.operands,
    };

    const call: Call = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .request = &input,
    };

    const root = generated.executeIn(temporary, &call) catch |err|
        return @import("../construction/publication.zig").failure(err);

    return @fromBackingInt(root);
}
