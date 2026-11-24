const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const apply = @import("apply.zig");
const preparation = @import("generated_prepare_construction");
const generated = @import("generated_construction");

pub fn lower(self: *Lower, id: ir.TypeId, value: node.ExpressionId, layout: ?node.ExpressionId) Lower.Error!node.ExpressionId {
    const Preparation = std.meta.Child(preparation.Input);
    const index = @backingInt(id);
    const selected = self.state_active and self.state_plan.selected[index];
    const target = if (layout) |item| @backingInt(item) else null;

    const request: Preparation = .{
        .frame = @ptrCast(self),
        .id = index,
        .policy = &.{
            .active = self.state_active,
            .selected = selected,
            .borrowed = index < self.state_plan.borrowed.len and self.state_plan.borrowed[index],
        },
        .target = target,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const serial = self.serial;
    const declarations = self.task_declarations.count();
    const statements = self.builder.nodes.statements.tags.items.len;
    const references = self.referenceBatches();
    const temporary = buffered.allocator();
    const resources = preparation.executeValue(temporary, &request) catch |err| return @import("publication.zig").failure(err);
    const Request = std.meta.Child(generated.Input);
    const Input = std.meta.Child(@FieldType(Request, "construction"));
    const kind = self.program.typeOf(id);
    const ast = @import("ast.zig").borrow(std.meta.Child(@FieldType(Input, "ast")), self);

    std.debug.assert(serial == self.serial and declarations == self.task_declarations.count());
    std.debug.assert(statements == self.builder.nodes.statements.tags.items.len and references == self.referenceBatches());

    const construction: Input = .{
        .mode = @fromBackingInt(@backingInt(resources.mode)),
        .ast = &ast,
        .value = @backingInt(value),
        .layout = resources.layout,
        .type_expr = resources.type_expr,
        .storage_layout = resources.storage_layout,
        .is_tuple = kind == .tuple,
        .arity = if (kind == .tuple) kind.tuple.len else 0,
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .serial = self.serial,
    };

    const input: Request = .{ .construction = &construction, .target = target, .origin = selected };
    const output = generated.executeIn(temporary, &input) catch |err| return @import("publication.zig").failure(err);

    return publish(self, output);
}

pub fn publish(self: *Lower, output: anytype) Lower.Error!node.ExpressionId {
    if (!output.valid) return error.OutOfMemory;
    try apply.expressions(self, output);
    try apply.rows(self, &self.builder.nodes.statements, output.statements);
    try apply.storage(self, output);

    self.serial = @intCast(output.serial);
    self.uses_allocator = self.uses_allocator or output.uses_allocator;

    return @fromBackingInt(output.root);
}
