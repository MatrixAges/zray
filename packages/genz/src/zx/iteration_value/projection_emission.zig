const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const Consumer = @import("../iteration_consumer.zig").Consumer;
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

    const preparation: Prepare = .{
        .source = &request,
        .resources = &.{
            .frame = @ptrCast(self),
            .writer = @ptrCast(self),
            .context = @ptrCast(context),
            .history_count = context.transfers.len(),
        },
    };

    const prepared = preparer.executeIn(temporary, &preparation) catch |err| return emissionFailure(err);

    if (!prepared.plan.valid) unreachable;
    if (prepared.plan.operations.len == 0) return value;

    const emitter = @import("generated_projection_emit");
    const Call = std.meta.Child(emitter.Input);
    const Input = std.meta.Child(@FieldType(Call, "projection"));
    const history = context.transfers.view(std.meta.Child(@FieldType(Input, "history")));

    const input: Input = .{
        .plan = zx.columns.pointer(@FieldType(Input, "plan"), prepared.plan),
        .prepared = prepared.prepared,
        .serials = prepared.serials,
        .history_count = prepared.history_count,
        .history = &history,
        .value = @backingInt(value),
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const call: Call = .{
        .writer = @ptrCast(self),
        .projection = &input,
    };

    const root = emitter.executeIn(temporary, &call) catch |err| return emissionFailure(err);

    return @fromBackingInt(root);
}
