const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const aggregate = @import("../aggregate.zig");
const publication = @import("../construction/publication.zig");
const entry = @import("generated_execute_transform");
const Input = std.meta.Child(entry.Input);
const Ast = std.meta.Child(@FieldType(Input, "ast"));
const RenewalSource = std.meta.Child(std.meta.Child(@FieldType(Input, "renewal_source")));
const RenewalWorkspace = @import("../growth/renew_workspace.zig");
const Error = Lower.Error;

pub const Frame = struct {
    lowering: *Lower,
    id: ir.ExprId,
    transform: ir.Transform,
    body: Sequence,
    loop: Sequence,
    binding: Sequence,
    added: []const ir.SymbolId = &.{},
    entered: node.Block = .{},
    renewal_workspace: *RenewalWorkspace = undefined,
    pub fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    pub fn typeId(self: *const Frame) ir.TypeId {
        return @fromBackingInt(self.lowering.program.expressions.types[@backingInt(self.id)]);
    }
    pub fn sourceType(self: *const Frame) ir.TypeId {
        return @fromBackingInt(self.lowering.program.expressions.types[@backingInt(self.transform.target)]);
    }
    fn deinit(self: *Frame) void {
        self.binding.deinit();
        self.loop.deinit();
        self.body.deinit();
        self.lowering.state_symbols.removeMany(self.added);
    }
};

pub fn lower(self: *Lower, id: ir.ExprId, transform: ir.Transform) Error!node.ExpressionId {
    comptime @import("../../node/view.zig").compatible(@FieldType(ir.Transform, "kind"), @FieldType(Input, "kind"));

    var frame: Frame = .{
        .lowering = self,
        .id = id,
        .transform = transform,
        .body = self.builder.statementSequence(self.workspace),
        .loop = self.builder.statementSequence(self.workspace),
        .binding = self.builder.statementSequence(self.workspace),
    };

    defer frame.deinit();

    if (transform.kind == .reduce and self.plan.renewals.keys.len != 0) {
        return RenewalWorkspace.run(&frame, RenewalSource, .{ .type_id = frame.typeId(), .roots = &.{} }, execute);
    }

    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    return execute(&frame, scratch.allocator(), null);
}

fn execute(frame: *Frame, temporary: std.mem.Allocator, renewal_source: ?*const RenewalSource) Error!node.ExpressionId {
    var origin: publication.OriginBuffer = .{};

    const ast: Ast = .{
        .writer = @ptrCast(frame.lowering),
        .lower = @ptrCast(frame.lowering),
        .origin = @ptrCast(&origin),
        .body = @ptrCast(&frame.body),
        .loop = @ptrCast(&frame.loop),
        .binding = @ptrCast(&frame.binding),
    };

    const input: Input = .{
        .frame = @ptrCast(frame),
        .ast = &ast,
        .kind = @fromBackingInt(@backingInt(frame.transform.kind)),
        .id = @backingInt(frame.id),
        .renewal_source = renewal_source,
    };

    const value = entry.executeIn(temporary, &input) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };

    return @fromBackingInt(value.?);
}

pub fn lowerTransformSort(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../sorting/root.zig").lower(frame.lowering, frame.id, frame.transform));
}

pub fn enterTransformParameters(handle: *const anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.added = try @import("../state_value/locals.zig").parameters(frame.lowering, frame.transform);
}

pub fn tryTransformSimd(handle: *const anyopaque) Error!?u32 {
    const frame = Frame.borrow(handle);
    const value = try @import("../simd/root.zig").lower(frame.lowering, frame.id, frame.transform) orelse return null;

    return @backingInt(value);
}

pub fn bindTransformSource(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const value = try @import("../state_value/list.zig").expression(self, frame.transform.target);

    return @backingInt(try aggregate.bind(self, &frame.body, value));
}

pub fn resolveTransformResultType(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.lowering.typeExpr(frame.typeId()));
}

pub fn lowerTransformCallback(handle: *const anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try frame.lowering.expr(frame.transform.body));
}

pub fn transformFreshName(handle: *const anyopaque, prefix: []const u8) Error![]const u8 {
    return Frame.borrow(handle).lowering.fresh(prefix);
}

pub fn transformContextInitial(handle: *const anyopaque) ?u32 {
    const id = Frame.borrow(handle).transform.initial orelse return null;

    return @backingInt(id);
}

pub fn lowerTransformContextInitial(handle: *const anyopaque, id: u32) Error!u32 {
    return @backingInt(try Frame.borrow(handle).lowering.expr(@fromBackingInt(id)));
}

pub fn publishTransformContext(handle: *const anyopaque, value: u32) Error!void {
    const frame = Frame.borrow(handle);

    return @import("context.zig").publish(frame.lowering, &frame.body, frame.transform.parameters[1], @fromBackingInt(value));
}

pub fn bindTransformElement(handle: *const anyopaque) Error![]const u8 {
    const frame = Frame.borrow(handle);
    const element = frame.transform.parameters[@intFromBool(frame.transform.kind == .reduce)];

    return @import("../state_value/elements.zig").captureName(frame.lowering, &frame.binding, frame.sourceType(), element);
}

pub fn transformStateActive(handle: *const anyopaque) bool {
    return Frame.borrow(handle).lowering.state_active;
}
