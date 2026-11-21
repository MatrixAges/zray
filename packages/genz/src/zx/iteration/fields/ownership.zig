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

    @import("../../../node/import_rows.zig").appendBorrowed(lowering.allocator, &lowering.builder.nodes.expressions, planned.expressions) catch |err| return failure(err);

    const replacements = try temporary.alloc(u32, planned.requests.fields.len);

    if (replacements.len != 0) {
        const frame: Frame = .{ .lowering = lowering, .body = body, .origin = @fromBackingInt(planned.origin) };
        const apply = @import("generated_apply_loop_field_projection");
        const Apply = std.meta.Child(apply.Input);

        const edits: Apply = .{
            .target = @ptrCast(&frame),
            .requests = zx.columns.pointer(@FieldType(Apply, "requests"), planned.requests),
            .values = planned.values,
            .replacements = @ptrCast(&replacements),
        };

        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        apply.executeIn(fixed.allocator(), &edits) catch |err| return failure(err);
    }

    const layout = request.layout orelse try lowering.layoutExpr(self.type_id);

    return try projection.rebuild(self, lowering, request.value, layout, .{
        .values = planned.values,
        .changed = planned.requests.fields,
        .replacements = replacements,
    });
}

const Frame = struct {
    lowering: *Lower,
    body: *Statements,
    origin: ir.ExprId,
};

pub fn projectLoopField(target: *const anyopaque, type_id: u32, value: u32, slot: u32) Lower.Error!u32 {
    const frame: *const Frame = @ptrCast(@alignCast(target));

    return @backingInt(try ownership.lower(
        frame.lowering,
        frame.body,
        frame.origin,
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
