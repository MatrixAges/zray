const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");

pub fn lower(self: *Lower, body: anytype, id: ir.ExprId, type_id: ir.TypeId, value: node.ExpressionId, slot: u32, required: bool) Lower.Error!node.ExpressionId {
    const preparation = @import("generated_prepare_ownership_projection");
    const Request = std.meta.Child(preparation.Input);
    const PlanInput = std.meta.Child(@FieldType(Request, "plan"));
    const Outline = std.meta.Child(@FieldType(PlanInput, "source"));
    const Query = std.meta.Child(@FieldType(Outline, "source"));
    const Facts = std.meta.Child(@FieldType(Query, "facts"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), self.program.types);
    const facts = @import("query.zig").borrowFacts(Facts, self, &types);
    const query: Query = .{ .facts = &facts, .node = @backingInt(id), .type_id = @backingInt(type_id), .slot = slot };
    const outline: Outline = .{ .source = &query, .referenced = self.state_plan.borrowed };
    var hash: zx.Sha256 = undefined;
    const hash_state = zx.Sha256State{ .value = &hash };

    const plan_input: PlanInput = .{
        .source = &outline,
        .hash = @ptrCast(&hash_state),
        .names = self.type_names,
        .existing_names = self.task_declarations.functionNames(),
        .key = &self.state_plan.keys[@backingInt(type_id)],
        .serial = self.serial,
        .required = required,
    };

    const layouts: []const u32 = @ptrCast(self.state_layouts);
    const request: Request = .{ .frame = @ptrCast(self), .plan = &plan_input, .layouts = layouts };
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = buffered.allocator();
    const prepared = (preparation.executeIn(temporary, &request) catch |err| return failure(err)) orelse return value;
    const emitter = @import("generated_ownership_projection");
    const CallRequest = std.meta.Child(emitter.Input);
    const Input = std.meta.Child(@FieldType(CallRequest, "projection"));
    const Helper = @typeInfo(@FieldType(Input, "helper")).optional.child;
    const Clear = @typeInfo(@FieldType(Input, "clear_plan")).optional.child;
    const ast = zx.columns.view(std.meta.Child(@FieldType(Input, "ast")), @import("../list_emission.zig").borrow(self));

    const input: Input = .{
        .source = zx.columns.pointer(@FieldType(Input, "source"), &outline),
        .name = prepared.name,
        .helper = if (prepared.helper) |helper| zx.columns.pointer(Helper, helper) else null,
        .clear_plan = if (prepared.clear_plan) |clear| zx.columns.pointer(Clear, clear) else null,
        .layouts = layouts,
        .type_expr = prepared.type_expr,
        .value = @backingInt(value),
        .ast = &ast,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .declaration_base = @intCast(self.task_declarations.count()),
        .serial = self.serial,
    };

    const call: CallRequest = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .body = @ptrCast(body),
        .projection = &input,
    };

    const root = emitter.executeIn(temporary, &call) catch |err| return failure(err);

    return @fromBackingInt(root);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid ownership projection generation"),
    };
}
