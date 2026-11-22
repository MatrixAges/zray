const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");
const emit = @import("emitting.zig");
const Branches = @FieldType(@FieldType(zx.ir.ExpressionRow, "value"), "parallel");
const Sequence = @import("../../node/blocks.zig").Sequence;

const Frame = struct {
    lowering: *Lower,
    type_id: zx.ir.TypeId,
    fields: []const ?u32,
    futures: [][]const u8,
    temporary: std.mem.Allocator,
    body: Sequence,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn lower(self: *Lower, type_id: zx.ir.TypeId, branches: Branches) Lower.Error!node.ExpressionId {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();

    var frame: Frame = .{
        .lowering = self,
        .type_id = type_id,
        .fields = branches.fields[0..branches.len],
        .futures = try temporary.alloc([]const u8, branches.len),
        .temporary = temporary,
        .body = self.builder.statementSequence(temporary),
    };

    const entry = @import("generated_lower_parallel");

    const input: std.meta.Child(entry.Input) = .{
        .group = @ptrCast(&frame),
        .tasks = branches.tasks[0..branches.len],
    };

    return @import("../expressions/evaluate.zig").invoke(entry, &input);
}

pub fn startParallelBranch(handle: *const anyopaque, index: u64, task: u32) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const future = (try emit.open(self, true)).?;

    frame.futures[@intCast(index)] = future;

    try frame.body.append(try @import("root.zig").bind(self, future, @fromBackingInt(task), true));
}

pub fn finishParallel(handle: *const anyopaque) Lower.Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const completed = try complete(self, frame.type_id, frame.futures, frame.fields, frame.temporary);

    try frame.body.append(completed.block);

    return @backingInt(try @import("../aggregate.zig").finishStored(self, try frame.body.finish(self.allocator), completed.value, null));
}

fn complete(self: *Lower, type_id: zx.ir.TypeId, futures: []const []const u8, fields: []const ?u32, temporary: std.mem.Allocator) Lower.Error!emit.Started {
    const results = try temporary.alloc([]const u8, fields.len);
    const values = try temporary.alloc([]const u8, fields.len);
    const labels = @import("generated_task_parallel_labels");

    const names: std.meta.Child(labels.Input) = .{
        .serial = self.serial,
        .fields = fields,
        .results = @ptrCast(&results),
        .values = @ptrCast(&values),
    };

    self.serial = @intCast(zx.columns.invoke(labels.executeValue, self.allocator, &names) catch |err| return emit.failure(err));

    const entry = @import("generated_task_parallel_result");
    const Input = std.meta.Child(entry.Input);
    const output_type = self.program.typeOf(type_id);
    const bases = emit.context(std.meta.Child(@FieldType(Input, "bases")), self);

    const input: Input = .{
        .futures = futures,
        .results = results,
        .values = values,
        .fields = fields,
        .object_names = if (output_type == .object) output_type.object.names else null,
        .bases = &bases,
    };

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, temporary);
    const compiled = entry.executeIn(memory.allocator(), &input) catch |err| return emit.failure(err);

    if (!compiled.valid) return error.OutOfMemory;

    const expressions = view.join(compiled.expressions.*, compiled.forms.*);

    try emit.append(self, &self.builder.nodes.expressions, &expressions);

    _ = @import("../../node/import_fields.zig").appendBorrowingText(self.allocator, &self.builder.nodes.field_columns, compiled.fields) catch |err| return emit.failure(err);

    const block = try self.builder.publishStatements(compiled.statements);
    const root: node.ExpressionId = @fromBackingInt(compiled.root);
    const value = if (compiled.construct) try self.construct(type_id, root) else root;

    return .{ .block = block, .value = value };
}
