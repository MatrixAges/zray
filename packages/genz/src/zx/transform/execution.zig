const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
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
    members: ?@import("../members.zig").Checkpoint = null,
    renewal_workspace: *RenewalWorkspace = undefined,
    pub fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
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
        if (self.members) |before| self.lowering.state_symbols.restore(before);
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
    const self = frame.lowering;
    const transform = frame.transform;
    const has_context = transform.kind != .reduce and transform.initial != null;
    const context_symbol = if (has_context) @backingInt(transform.parameters[1]) else 0;
    const context_used = has_context and self.used[context_symbol];
    const element_symbol: u32 = if (transform.kind == .filter) @backingInt(transform.parameters[0]) else 0;
    var used = std.mem.sliceAsBytes(self.used);
    var origin: publication.OriginBuffer = .{};

    const ast: Ast = .{
        .writer = @ptrCast(self),
        .lower = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .body = @ptrCast(&frame.body),
        .loop = @ptrCast(&frame.loop),
        .binding = @ptrCast(&frame.binding),
    };

    const input: Input = .{
        .frame = @ptrCast(frame),
        .ast = &ast,
        .kind = @fromBackingInt(@backingInt(transform.kind)),
        .id = @backingInt(frame.id),
        .target = @backingInt(transform.target),
        .result_type = @backingInt(frame.typeId()),
        .result_selected = @import("../state_value/list.zig").selected(self, frame.typeId()),
        .body_expr = @backingInt(transform.body),
        .initial = if (transform.initial) |initial| @backingInt(initial) else null,
        .context_used = context_used,
        .context_name = if (context_used) self.names[context_symbol] else &.{},
        .context_type = if (has_context) self.program.symbols.types[context_symbol] else 0,
        .element_symbol = element_symbol,
        .element_name = if (transform.kind == .filter) self.names[element_symbol] else &.{},
        .used = @ptrCast(&used),
        .state_active = self.state_active,
        .inline_lists = if (self.iteration_value) |context| context.inline_lists else false,
        .accumulator = if (transform.kind == .reduce) self.names[@backingInt(transform.parameters[0])] else &.{},
        .renewal_source = renewal_source,
    };

    const value = entry.executeIn(temporary, &input) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };

    return @fromBackingInt(value.?);
}

pub fn lowerTransformSort(handle: *anyopaque) Error!u32 {
    const frame = Frame.borrow(handle);

    return @backingInt(try @import("../sorting/root.zig").lower(frame.lowering, frame.id, frame.transform));
}

pub fn enterTransformParameters(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    frame.members = try @import("../state_value/locals.zig").parameters(frame.lowering, frame.transform);
}

pub fn tryTransformSimd(handle: *anyopaque) Error!?u32 {
    const frame = Frame.borrow(handle);
    const value = try @import("../simd/root.zig").lower(frame.lowering, frame.id, frame.transform) orelse return null;

    return @backingInt(value);
}

pub fn bindTransformElement(handle: *anyopaque) Error![]const u8 {
    const frame = Frame.borrow(handle);
    const element = frame.transform.parameters[@intFromBool(frame.transform.kind == .reduce)];

    return @import("../state_value/elements.zig").captureName(frame.lowering, &frame.binding, frame.sourceType(), element);
}
