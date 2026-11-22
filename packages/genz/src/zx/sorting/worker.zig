const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const emitting = @import("worker/emitting.zig");
const scope = @import("../functions/scope.zig");
const Error = Lower.Error;
pub const Result = struct { declaration: u32, io: bool, process: bool };

const Frame = struct {
    lowering: *Lower,
    value: ir.Transform,
    worker: *Lower,
    final: emitting.Final,
    helper: @import("../../node/blocks.zig").Sequence,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn build(self: *Lower, value: ir.Transform, child: node.ExpressionId, errors: ?[]const []const u8) Error!Result {
    var worker = scope.inherit(self, .Sort);

    try scope.reserve(&worker, self.allocator, .Sort);

    const prepared = try emitting.prepare(self);
    var saved: [prepared.names.len][]const u8 = undefined;
    const names = @import("../scope/reuse.zig").bindNames(self, value.parameters, &prepared.names, &saved);

    defer names.restore(self);

    var frame: Frame = .{
        .lowering = self,
        .value = value,
        .worker = &worker,
        .final = .{
            .worker = &worker,
            .environment = value.parameters[2],
            .child = child,
            .output_type = undefined,
            .errors = errors,
            .value = undefined,
            .raw = prepared.raw,
            .elements = prepared.raw,
            .used = @splat(false),
            .helpers = @splat(.{}),
        },
        .helper = self.builder.statementSequence(self.workspace),
    };

    defer frame.helper.deinit();

    const declaration = try @import("../expressions/evaluate.zig").invoke(@import("generated_execute_sort_worker"), @ptrCast(&frame));

    return .{ .declaration = @backingInt(declaration), .io = worker.uses_io, .process = worker.uses_process };
}

pub fn registerSortParameters(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    try @import("../state_value/locals.zig").registerOwned(frame.worker, frame.value.parameters);
}

pub fn evaluateSortComparator(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.final.value = try frame.worker.expr(frame.value.body);
}

pub fn sortOperandUsed(handle: *const anyopaque, index: u64) bool {
    const frame = Frame.borrow(handle);

    return frame.worker.used[@backingInt(frame.value.parameters[@intCast(index)])];
}

pub fn readSortOperand(handle: *const anyopaque, index: u64) Error!void {
    const frame = Frame.borrow(handle);
    const slot: usize = @intCast(index);
    const list_type = frame.lowering.program.expression(frame.value.target).type_id;

    frame.final.elements[slot] = try @import("../state_value/elements.zig").read(frame.worker, &frame.helper, list_type, frame.final.raw[slot]);
    frame.final.helpers[slot] = try frame.helper.block(frame.lowering.allocator);
    frame.final.used[slot] = true;

    frame.helper.clearRetainingCapacity();
}

pub fn publishSortWorker(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);
    const output_type = frame.lowering.program.expression(frame.value.body).type_id;

    frame.final.output_type = try frame.lowering.typeExpr(output_type);

    return emitting.finish(frame.lowering, frame.final);
}
