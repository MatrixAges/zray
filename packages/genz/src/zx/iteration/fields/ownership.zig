const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Context = @import("root.zig");
const aggregate = @import("../../aggregate.zig");
const ownership = @import("../../state_value/ownership/projection.zig");
const projection = @import("projection.zig");
const entry = @import("generated_loop_fields_ownership");
const Statements = @import("../../iteration_value/root.zig").Statements;

pub fn maskBorrowed(self: *Context, lowering: *Lower, body: anytype) Lower.Error!void {
    const masked = try rebuild(self, lowering, body, .{ .value = self.seed }) orelse return;

    self.seed = try aggregate.bind(lowering, body, masked);
}

pub fn qualify(self: *const Context, lowering: *Lower, body: anytype, id: ir.ExprId, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    const source = try aggregate.bind(lowering, body, value);

    return (try rebuild(self, lowering, body, .{ .value = source, .origin = id, .layout = self.layout })).?;
}

const Request = struct {
    value: node.ExpressionId,
    origin: ?ir.ExprId = null,
    layout: ?node.ExpressionId = null,
};

fn rebuild(self: *const Context, lowering: *Lower, body: anytype, request: Request) Lower.Error!?node.ExpressionId {
    const Input = std.meta.Child(entry.Input);
    const Facts = std.meta.Child(@FieldType(Input, "facts"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), lowering.program.types);

    const facts: Facts = .{
        .types = &types,
        .selected = lowering.state_plan.selected,
        .counts = lowering.slot_counts,
        .first = lowering.plan.slot_first,
        .transfers = lowering.plan.transfers,
    };

    const input: Input = .{
        .facts = &facts,
        .type_id = @backingInt(self.type_id),
        .borrowed = self.borrowed,
        .origin = if (request.origin) |origin| @backingInt(origin) else null,
        .value = @backingInt(request.value),
        .expression_base = @intCast(lowering.builder.nodes.expressions.tags.items.len),
    };

    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const planned = (entry.executeIn(temporary, &input) catch |err| return failure(err)) orelse return null;

    if (!planned.valid) return error.OutOfMemory;

    const execute = @import("generated_rebuild_loop_fields");
    const ExecInput = std.meta.Child(execute.Input);

    const request_execution: ExecInput = .{
        .frame = @ptrCast(lowering),
        .writer = @ptrCast(lowering),
        .body = @ptrCast(body),
        .origin = planned.origin,
        .expressions = zx.columns.pointer(@FieldType(ExecInput, "expressions"), planned.expressions),
        .requests = zx.columns.pointer(@FieldType(ExecInput, "requests"), planned.requests),
        .values = planned.values,
        .type_id = @backingInt(self.type_id),
        .layout = if (request.layout) |layout| @backingInt(layout) else null,
    };

    const result = execute.executeIn(temporary, &request_execution) catch |err| return failure(err);

    return try projection.rebuild(self, lowering, request.value, @fromBackingInt(result.layout), .{
        .values = planned.values,
        .changed = planned.requests.fields,
        .replacements = result.replacements,
    });
}

pub fn projectLoopField(writer: *anyopaque, sequence: *anyopaque, origin: u32, type_id: u32, value: u32, slot: u32) Lower.Error!u32 {
    const lowering = @import("../../expressions/evaluate.zig").borrow(writer);
    const body: *Statements = @ptrCast(@alignCast(sequence));

    return @backingInt(try ownership.lower(
        lowering,
        body,
        @fromBackingInt(origin),
        @fromBackingInt(type_id),
        @fromBackingInt(value),
        slot,
        true,
    ));
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
