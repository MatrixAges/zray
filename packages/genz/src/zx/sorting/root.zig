const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const blocks = @import("../../node/blocks.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const aggregate = @import("../aggregate.zig");
const lists = @import("../state_value/list.zig");
const functions = @import("functions.zig");
const emission = @import("emitting.zig");
const worker = @import("worker.zig");
const Error = Lower.Error;

const Frame = struct {
    lowering: *Lower,
    id: ir.ExprId,
    value: ir.Transform,
    list_type: ir.TypeId,
    body: blocks.Sequence,
    slot: usize = undefined,
    name: []const u8 = undefined,
    child: node.ExpressionId = undefined,
    errors: ?[]const []const u8 = undefined,
    comparator: worker.Result = undefined,
    helpers: [2]u32 = undefined,
    target: node.ExpressionId = undefined,
    source: node.ExpressionId = undefined,
    reuse: node.ExpressionId = undefined,
    environment: node.ExpressionId = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn lower(self: *Lower, id: ir.ExprId, value: ir.Transform) Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("root_seed.zig").lower(self, id, value);

    var frame: Frame = .{
        .lowering = self,
        .id = id,
        .value = value,
        .list_type = self.program.expression(value.target).type_id,
        .body = self.builder.statementSequence(self.workspace),
    };

    defer frame.body.deinit();

    return evaluation.invoke(@import("generated_execute_sort"), @ptrCast(&frame));
}

pub fn reserveSortDeclaration(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.slot = frame.lowering.task_declarations.count();
    frame.name = try emission.reserve(frame.lowering, frame.slot);
}

pub fn prepareSortTypes(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.child = try @import("../state_value/elements.zig").typeExpr(frame.lowering, frame.list_type);
    frame.errors = try @import("../error_effects.zig").expression(frame.lowering, frame.id);
}

pub fn buildSortComparator(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.comparator = try worker.build(frame.lowering, frame.value, frame.child, frame.errors);
}

pub fn buildSortHelpers(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.helpers = try functions.build(frame.lowering, frame.child, frame.errors);
}

pub fn publishSortHelpers(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const ids = [_]u32{ frame.comparator.declaration, frame.helpers[0], frame.helpers[1] };
    const declarations = try blocks.joinDeclarations(self.allocator, self.builder.nodes, &ids, &.{ 1, 1, 1 });

    try emission.publish(self, frame.slot, frame.name, declarations);
}

pub fn publishSortEffects(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    self.uses_allocator = true;
    self.uses_io = self.uses_io or frame.comparator.io;
    self.uses_process = self.uses_process or frame.comparator.process;
}

pub fn evaluateSortTarget(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.lowering.expr(frame.value.target));
}

pub fn sortSourceSelected(handle: *const anyopaque) bool {
    const frame = Frame.borrow(handle);

    return lists.selected(frame.lowering, frame.list_type);
}

pub fn clipSortTarget(handle: *const anyopaque, target: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const ownership = @import("../state_value/ownership.zig");

    return @backingInt(try ownership.clip(frame.lowering, &frame.body, frame.value.target, @fromBackingInt(target)));
}

pub fn bindSortTarget(handle: *const anyopaque, target: u32) Error!void {
    const frame = Frame.borrow(handle);

    frame.target = try aggregate.bind(frame.lowering, &frame.body, @fromBackingInt(target));
    frame.source = try lists.items(frame.lowering, frame.list_type, frame.target);
}

pub fn sortInputReusable(handle: *const anyopaque) bool {
    const frame = Frame.borrow(handle);

    return frame.lowering.plan.get(frame.id).in_place;
}

pub fn sortWritable(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try lists.writable(frame.lowering, frame.target));
}

pub fn sortReuseFlag(handle: *const anyopaque, reuse: bool) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.lowering.builder.expression(.{ .boolean = reuse }));
}

pub fn bindSortReuse(handle: *const anyopaque, reuse: u32) Error!void {
    const frame = Frame.borrow(handle);

    frame.reuse = try aggregate.bind(frame.lowering, &frame.body, @fromBackingInt(reuse));
}

pub fn bindSortEnvironment(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const environment = try frame.lowering.expr(frame.value.initial.?);

    frame.environment = try aggregate.bind(frame.lowering, &frame.body, environment);
}

pub fn readSortHeader(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try lists.headered(frame.lowering, frame.target));
}

pub fn emitSort(handle: *const anyopaque, selected: bool, header: u32) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    const result = try emission.expression(self, &frame.body, .{
        .name = frame.name,
        .source = frame.source,
        .reuse = frame.reuse,
        .environment = frame.environment,
        .errors = frame.errors,
        .io = frame.comparator.io,
        .process = frame.comparator.process,
        .selected = selected,
        .headered = @fromBackingInt(header),
    });

    return @backingInt(try aggregate.finish(self, &frame.body, try lists.owned(self, frame.list_type, result.value, result.headered)));
}
