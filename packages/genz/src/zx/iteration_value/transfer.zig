const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const generated = @import("generated_iteration_transfer");
const Store = std.meta.Child(@FieldType(generated.zx_pending, "store_0"));

const Host = struct {
    context: *Context,
    store_0: *Store,
    pub fn commit(host: *Host, pending: anytype) Lower.Error!void {
        const record = pending.store_0 orelse return;
        const context = host.context;

        try context.transfers.retain(context.lowering.allocator, record.type_id, record.owner, record.value, record.ready);

        host.store_0.* = record;
    }
};

pub const Result = struct {
    root: node.ExpressionId,
    cached: node.ExpressionId,
};

pub fn lower(context: *Context, body: anytype, type_id: ir.TypeId, source: node.ExpressionId) Lower.Error!Result {
    const self = context.lowering;
    const kind = try self.typeExpr(type_id);
    const element = try self.typeExpr(self.program.typeOf(type_id).list);
    const Call = std.meta.Child(generated.Input);
    const Input = std.meta.Child(@FieldType(Call, "request"));
    const history = context.transfers.view(std.meta.Child(@FieldType(Input, "history")));

    const input: Input = .{
        .type_id = @backingInt(type_id),
        .kind = @backingInt(kind),
        .element = @backingInt(element),
        .value = @backingInt(source),
        .history = &history,
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .serial = self.serial,
    };

    const call: Call = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .body = @ptrCast(body),
        .request = &input,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    var store: Store = &.{ .type_id = 0, .owner = 0, .value = 0, .ready = 0 };
    var host: Host = .{ .context = context, .store_0 = &store };
    const published = generated.executeIn(buffered.allocator(), &call, &host) catch |err| return @import("../construction/publication.zig").failure(err);

    return .{ .root = @fromBackingInt(published.root), .cached = @fromBackingInt(published.cached) };
}
