const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const publication = @import("publication.zig");
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
            .borrowed = layout == null and @import("borrow.zig").proven(self, id, value, selected),
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
    const resources = preparation.executeValue(temporary, &request) catch |err| return publication.failure(err);
    const CallRequest = std.meta.Child(generated.Input);
    const Request = std.meta.Child(@FieldType(CallRequest, "request"));
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

    const request_body: Request = .{ .construction = &construction, .target = target, .origin = selected };
    const call: CallRequest = .{ .frame = @ptrCast(self), .writer = @ptrCast(self), .request = &request_body };
    const root = generated.executeIn(temporary, &call) catch |err| return publication.failure(err);

    return @fromBackingInt(root);
}
