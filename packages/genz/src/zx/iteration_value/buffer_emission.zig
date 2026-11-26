const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");

pub fn view(context: *Context, id: ir.TypeId, owner: node.ExpressionId, items: node.ExpressionId, owned: bool) Lower.Error!node.ExpressionId {
    const self = context.lowering;
    const layout = try @import("types.zig").get(context, id);
    const generated = @import("generated_iteration_buffer_view");
    const Call = std.meta.Child(generated.Input);
    const Input = std.meta.Child(@FieldType(Call, "view"));

    const input: Input = .{
        .layout = @backingInt(layout),
        .owner = @backingInt(owner),
        .items = @backingInt(items),
        .owned = owned,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
    };

    const call: Call = .{
        .writer = @ptrCast(self),
        .view = &input,
    };

    return emitObject(self, generated, &call);
}

pub fn redirect(context: *Context, id: ir.TypeId, source: node.ExpressionId) Lower.Error!node.ExpressionId {
    const self = context.lowering;
    const layout = try @import("types.zig").get(context, id);
    const generated = @import("generated_iteration_buffer_redirect");
    const Call = std.meta.Child(generated.Input);
    const Input = std.meta.Child(@FieldType(Call, "redirect"));
    const history = context.transfers.view(std.meta.Child(@FieldType(Input, "history")));

    const input: Input = .{
        .type_id = @backingInt(id),
        .layout = @backingInt(layout),
        .value = @backingInt(source),
        .history = &history,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
    };

    const call: Call = .{
        .writer = @ptrCast(self),
        .redirect = &input,
    };

    return emitObject(self, generated, &call);
}

fn emitObject(self: *Lower, comptime generated: type, input: anytype) Lower.Error!node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const root = generated.executeIn(buffered.allocator(), input) catch |err|
        return @import("../construction/publication.zig").failure(err);

    return @fromBackingInt(root);
}

pub fn prepare(context: *Context, body: anytype, source: node.ExpressionId) Lower.Error!void {
    const self = context.lowering;
    const generated = @import("generated_iteration_buffer_prepare");
    const Call = std.meta.Child(generated.Input);
    const Input = std.meta.Child(@FieldType(Call, "prepare"));

    const input: Input = .{
        .value = @backingInt(source),
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
    };

    const call: Call = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .body = @ptrCast(body),
        .prepare = &input,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    generated.executeIn(buffered.allocator(), &call) catch |err|
        return @import("../construction/publication.zig").failure(err);
}
