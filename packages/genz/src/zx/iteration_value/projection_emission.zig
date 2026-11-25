const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const Consumer = @import("../iteration_consumer.zig").Consumer;
const Api = @import("../expressions/evaluate.zig").Api;
const publication = @import("publication.zig");
const emissionFailure = @import("../construction/publication.zig").failure;

pub fn lower(context: *Context, selected: Consumer, id: ir.ExprId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    const self = context.lowering;
    const program: *const ir.Program = &self.program;
    const preparer = @import("generated_prepare_iteration_projection");
    const Prepare = std.meta.Child(preparer.Input);
    const PlanInput = std.meta.Child(@FieldType(Prepare, "source"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(PlanInput, "types")), self.program.types);

    const request: PlanInput = .{
        .types = &types,
        .table = zx.columns.pointer(@FieldType(PlanInput, "table"), &program.expressions),
        .root = @backingInt(id),
        .symbol = @backingInt(selected.symbol),
        .inline_lists = context.inline_lists,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = buffered.allocator();
    var timeline: Timeline = .{ .context = context };

    const preparation: Prepare = .{
        .source = &request,
        .resources = &.{
            .frame = @ptrCast(self),
            .context = @ptrCast(context),
            .history = @ptrCast(&timeline),
            .prepared = @ptrCast(&timeline.prepared),
            .serials = @ptrCast(&timeline.serials),
            .history_count = @ptrCast(&timeline.history_count),
        },
    };

    const plan = preparer.executeIn(temporary, &preparation) catch |err| return emissionFailure(err);

    if (!plan.valid) unreachable;
    if (plan.operations.len == 0) return value;

    const emitter = @import("generated_projection_emit");
    const Input = std.meta.Child(emitter.Input);
    const history = context.transfers.view(std.meta.Child(@FieldType(Input, "history")));

    const input: Input = .{
        .plan = zx.columns.pointer(@FieldType(Input, "plan"), plan),
        .prepared = timeline.prepared,
        .serials = timeline.serials,
        .history_count = timeline.history_count,
        .history = &history,
        .value = @backingInt(value),
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const output = emitter.executeIn(temporary, &input) catch |err| return emissionFailure(err);

    try publication.write(self, .Projection, .{}, output);

    return @fromBackingInt(output.root);
}

const Timeline = struct {
    context: *Context,
    prepared: []u32 = undefined,
    serials: []u64 = undefined,
    history_count: []u64 = undefined,
    stamp: Api.IterationProjectionStamp = undefined,
};

pub fn reserveIterationProjection(handle: *anyopaque, fresh: u64) Lower.Error!*const Api.IterationProjectionStamp {
    const timeline: *Timeline = @ptrCast(@alignCast(handle));
    const self = timeline.context.lowering;

    timeline.stamp = .{ .serial = self.serial, .history_count = timeline.context.transfers.len() };

    const reserved = std.math.cast(usize, fresh) orelse return error.OutOfMemory;
    self.serial = std.math.add(usize, self.serial, reserved) catch return error.OutOfMemory;

    return &timeline.stamp;
}
