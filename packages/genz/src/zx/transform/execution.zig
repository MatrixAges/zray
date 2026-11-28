const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const borrow = @import("../expressions/evaluate.zig").borrow;
const entry = @import("generated_execute_transform");
const Input = std.meta.Child(entry.Input);
const Ast = std.meta.Child(@FieldType(Input, "ast"));
const RenewalSource = std.meta.Child(std.meta.Child(@FieldType(Input, "renewal_source")));
const RenewalWorkspace = @import("../growth/renew_workspace.zig");
const Error = Lower.Error;

const Context = struct {
    lowering: *Lower,
    id: ir.ExprId,
    transform: ir.Transform,
    body: Sequence,
    loop: Sequence,
    binding: Sequence,
    renewal_workspace: *RenewalWorkspace = undefined,
    fn deinit(self: *Context) void {
        self.binding.deinit();
        self.loop.deinit();
        self.body.deinit();
    }
};

pub fn lower(self: *Lower, id: ir.ExprId, transform: ir.Transform) Error!node.ExpressionId {
    comptime @import("../../node/view.zig").compatible(@FieldType(ir.Transform, "kind"), @FieldType(Input, "kind"));

    var context: Context = .{
        .lowering = self,
        .id = id,
        .transform = transform,
        .body = self.builder.statementSequence(self.workspace),
        .loop = self.builder.statementSequence(self.workspace),
        .binding = self.builder.statementSequence(self.workspace),
    };

    const members = if (transform.kind != .sort) self.state_symbols.checkpoint() else null;

    defer if (members) |before| self.state_symbols.restore(before);
    defer context.deinit();

    if (transform.kind == .reduce and self.plan.renewals.keys.len != 0) {
        const type_id: ir.TypeId = @fromBackingInt(self.program.expressions.types[@backingInt(id)]);

        return RenewalWorkspace.run(&context, RenewalSource, .{ .type_id = type_id, .roots = &.{} }, execute);
    }

    var arena = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    return execute(&context, scratch.allocator(), null);
}

fn execute(context: *Context, temporary: std.mem.Allocator, renewal_source: ?*const RenewalSource) Error!node.ExpressionId {
    const self = context.lowering;
    const transform = context.transform;
    const result_type = self.program.expressions.types[@backingInt(context.id)];
    const has_context = transform.kind != .reduce and transform.initial != null;
    const context_symbol = if (has_context) @backingInt(transform.parameters[1]) else 0;
    const context_used = has_context and self.used[context_symbol];
    const element_symbol = if (transform.kind == .sort) 0 else @backingInt(transform.parameters[@intFromBool(transform.kind == .reduce)]);

    const ast: Ast = .{
        .writer = @ptrCast(self),
        .lower = @ptrCast(self),
        .body = @ptrCast(&context.body),
        .loop = @ptrCast(&context.loop),
        .binding = @ptrCast(&context.binding),
    };

    const input: Input = .{
        .ast = &ast,
        .kind = @fromBackingInt(@backingInt(transform.kind)),
        .id = @backingInt(context.id),
        .target = @backingInt(transform.target),
        .source_type = self.program.expressions.types[@backingInt(transform.target)],
        .result_type = result_type,
        .result_selected = @import("../state_value/list.zig").selected(self, @fromBackingInt(result_type)),
        .body_expr = @backingInt(transform.body),
        .initial = if (transform.initial) |initial| @backingInt(initial) else null,
        .context_used = context_used,
        .context_name = if (context_used) self.names[context_symbol] else &.{},
        .context_type = if (has_context) self.program.symbols.types[context_symbol] else 0,
        .element_symbol = element_symbol,
        .element_name = if (transform.kind == .filter) self.names[element_symbol] else &.{},
        .state_active = self.state_active,
        .inline_lists = if (self.iteration_value) |iteration| iteration.inline_lists else false,
        .accumulator = if (transform.kind == .reduce) self.names[@backingInt(transform.parameters[0])] else &.{},
        .renewal_source = renewal_source,
    };

    const value = entry.executeIn(temporary, &input) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };

    return @fromBackingInt(value.?);
}

pub fn lowerTransformSort(frame: *anyopaque, raw_id: u32) Error!u32 {
    const self = borrow(frame);
    const id: ir.ExprId = @fromBackingInt(raw_id);

    return @backingInt(try @import("../sorting/root.zig").lower(self, id, self.program.expression(id).value.transform));
}

pub fn enterTransformParameters(frame: *anyopaque, id: u32) Error!void {
    const self = borrow(frame);

    _ = try @import("../state_value/locals.zig").parameters(self, self.program.expression(@fromBackingInt(id)).value.transform);
}

pub fn tryTransformSimd(frame: *anyopaque, raw_id: u32) Error!?u32 {
    const self = borrow(frame);
    const id: ir.ExprId = @fromBackingInt(raw_id);
    const value = try @import("../simd/root.zig").lower(self, id, self.program.expression(id).value.transform) orelse return null;

    return @backingInt(value);
}

pub fn bindTransformElement(frame: *anyopaque, sequence: *anyopaque, source_type: u32, symbol: u32) Error![]const u8 {
    const body: *Sequence = @ptrCast(@alignCast(sequence));

    return @import("../state_value/elements.zig").captureName(borrow(frame), body, @fromBackingInt(source_type), @fromBackingInt(symbol));
}
