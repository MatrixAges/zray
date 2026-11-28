const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");

const CacheHost = struct {
    owner: *Context,
    store_0: *Record,
    const Emit = @import("generated_iteration_types_emit");
    const Record = std.meta.Child(@FieldType(Emit.zx_pending, "store_0"));

    pub fn commit(self: *CacheHost, pending: anytype) Lower.Error!void {
        const entry = pending.store_0 orelse return;

        try self.owner.types.put(
            self.owner.lowering.allocator,
            @fromBackingInt(entry.type_id),
            @fromBackingInt(entry.value),
        );

        self.store_0.* = entry;
    }
};

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

    const prepare: Prepare = .{
        .source = &request,
        .frame = @ptrCast(lowering),
    };

    const prepared = prepared: {
        var resources: Context.Resources = undefined;

        resources.push(self);
        defer resources.pop();

        break :prepared (preparation.executeIn(temporary, &prepare) catch |err|
            return @import("../construction/publication.zig").failure(err)) orelse return lowering.typeExpr(id);
    };

    const emitter = @import("generated_iteration_types_emit");
    const Call = std.meta.Child(emitter.Input);
    const EmitInput = std.meta.Child(@FieldType(Call, "request"));

    const input: EmitInput = .{
        .types = zx.columns.pointer(@FieldType(EmitInput, "types"), &types),
        .plan = zx.columns.pointer(@FieldType(EmitInput, "plan"), prepared.plan),
        .prepared = prepared.layouts,
        .expression_base = @intCast(lowering.builder.nodes.expressions.tags.items.len),
        .field_base = @intCast(lowering.builder.nodes.field_columns.count()),
        .serial = lowering.serial,
    };

    const call: Call = .{
        .frame = @ptrCast(lowering),
        .writer = @ptrCast(lowering),
        .body = @ptrCast(self.declarations),
        .request = &input,
    };

    var record: CacheHost.Record = &.{ .type_id = 0, .value = 0 };
    var host: CacheHost = .{ .owner = self, .store_0 = &record };

    const root = emitter.executeIn(buffered.allocator(), &call, &host) catch |err|
        return @import("../construction/publication.zig").failure(err);

    return @fromBackingInt(root);
}

pub fn element(lowering: *Lower, id: ir.TypeId) Lower.Error!node.ExpressionId {
    if (lowering.iteration_value) |context| if (context.inline_lists and @import("../iteration_layout.zig").represented(lowering, id)) return get(context, id);

    return try lowering.typeExpr(id);
}
