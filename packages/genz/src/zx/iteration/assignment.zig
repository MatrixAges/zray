const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");

pub const Write = struct {
    type_id: ir.TypeId,
    active: bool,
    target: node.ExpressionId,
    value: node.ExpressionId,
    mark: ?@FieldType(node.Statement, "assignment"),
};

pub fn lower(self: *Lower, write: Write) Lower.Error!u32 {
    const entry = @import("generated_iteration_assignment");
    const Input = std.meta.Child(entry.Input);
    const Facts = std.meta.Child(@FieldType(Input, "facts"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), self.program.types);
    const facts: Facts = .{ .types = &types, .selected = self.state_plan.selected };
    const Mark = std.meta.Child(@typeInfo(@FieldType(Input, "mark")).optional.child);

    const input: Input = .{
        .facts = &facts,
        .active = write.active,
        .type_id = @backingInt(write.type_id),
        .target = @backingInt(write.target),
        .value = @backingInt(write.value),
        .mark = if (write.mark) |value| &@as(Mark, .{ .target = @backingInt(value.target), .value = @backingInt(value.value) }) else null,
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .serial = self.serial,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!result.valid) return error.OutOfMemory;

    var publication: Publication = .{
        .lowering = self,
        .output = result,
        .names = try memory.allocator().alloc([]const u8, result.expressions.identifier.len),
        .fields = try memory.allocator().alloc([]const u8, result.expressions.field_name.len),
    };

    const publish = @import("generated_publish_loop_assignment");

    const input_publication: std.meta.Child(publish.Input) = .{
        .target = @ptrCast(&publication),
        .identifiers = publication.names.len,
        .field_origins = result.field_name_source,
    };

    try evaluation.execute(publish, &input_publication);

    return @intCast(result.statements.tags.len);
}

const evaluation = @import("../expressions/evaluate.zig");

const Publication = struct {
    lowering: *Lower,
    output: @import("generated_iteration_assignment").Output,
    names: [][]const u8,
    fields: [][]const u8,
    fn borrow(handle: *const anyopaque) *const Publication {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn ownLoopAssignmentIdentifier(handle: *const anyopaque, row: u64) Lower.Error!void {
    const frame = Publication.borrow(handle);
    const index: usize = @intCast(row);
    frame.names[index] = try frame.lowering.allocator.dupe(u8, frame.output.expressions.identifier[index]);
}

pub fn writeLoopAssignmentField(handle: *const anyopaque, row: u64, origin: u64, storage: evaluation.Api.LoopNameStorage) Lower.Error!void {
    const frame = Publication.borrow(handle);
    const index: usize = @intCast(row);
    const name = frame.output.expressions.field_name[index];

    frame.fields[index] = switch (storage) {
        .Borrow => name,
        .Own => try frame.lowering.allocator.dupe(u8, name),
        .Reuse => frame.fields[@intCast(origin)],
    };
}

pub fn appendLoopAssignmentExpressions(handle: *const anyopaque) Lower.Error!void {
    const frame = Publication.borrow(handle);
    const self = frame.lowering;
    var source = frame.output.expressions.*;
    source.identifier = frame.names;
    source.field_name = frame.fields;
    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.expressions, &source) catch |err| return failure(err);
}

pub fn appendLoopAssignmentStatements(handle: *const anyopaque) Lower.Error!void {
    const frame = Publication.borrow(handle);
    const self = frame.lowering;
    var source = frame.output.statements.*;
    source.constant_name = frame.names;

    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.statements, &source) catch |err| return failure(err);
}

pub fn finishLoopAssignment(handle: *const anyopaque) void {
    const frame = Publication.borrow(handle);

    frame.lowering.serial = @intCast(frame.output.serial);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
