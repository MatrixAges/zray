const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");

pub fn lower(self: *Lower, body: anytype, id: ir.ExprId, type_id: ir.TypeId, value: node.ExpressionId, slot: u32, required: bool) Lower.Error!node.ExpressionId {
    const planner = @import("generated_ownership_projection_plan");
    const PlanInput = std.meta.Child(planner.Input);
    const Outline = std.meta.Child(@FieldType(PlanInput, "source"));
    const Query = std.meta.Child(@FieldType(Outline, "source"));
    const Facts = std.meta.Child(@FieldType(Query, "facts"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), self.program.types);

    const facts: Facts = .{
        .types = &types,
        .selected = self.state_plan.selected,
        .counts = self.slot_counts,
        .first = self.plan.slot_first,
        .transfers = self.plan.transfers,
    };

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

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = buffered.allocator();
    const request = (planner.executeIn(temporary, &plan_input) catch |err| return failure(err)) orelse return value;
    const emitter = @import("generated_ownership_projection");
    const Input = std.meta.Child(emitter.Input);
    const Registration = std.meta.Child(@typeInfo(@FieldType(Input, "helper")).optional.child);
    const name = try self.allocator.dupe(u8, request.qualified.name);

    const helper: ?Registration = if (request.helper) |selected| .{
        .name = if (selected.registered) selected.name else try self.allocator.dupe(u8, selected.name),
        .registered = selected.registered,
    } else null;

    self.serial = @intCast(request.qualified.serial);

    const type_expr = try @import("../../types.zig").get(self, self.state_types, type_id);
    const layouts: []const u32 = @ptrCast(self.state_layouts);

    if (request.clear_plan) |plan| {
        if (plan.references.len != 0) {
            const prepare = @import("generated_prepare_ownership_layouts");

            const preparation: std.meta.Child(prepare.Input) = .{
                .frame = @ptrCast(self),
                .references = plan.references,
                .layouts = layouts,
            };

            prepare.executeIn(temporary, &preparation) catch |err| return failure(err);
        }
    }

    const ast = zx.columns.view(std.meta.Child(@FieldType(Input, "ast")), @import("../list_emission.zig").borrow(self));

    const input: Input = .{
        .source = &outline,
        .name = name,
        .helper = if (helper) |*selected| selected else null,
        .clear_plan = request.clear_plan,
        .layouts = layouts,
        .type_expr = @backingInt(type_expr),
        .value = @backingInt(value),
        .ast = &ast,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .declaration_base = @intCast(self.task_declarations.count()),
        .serial = self.serial,
    };

    const output = emitter.executeIn(temporary, &input) catch |err| return failure(err);

    try @import("../publication.zig").projection(self, body, output);

    return @fromBackingInt(output.root);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid ownership projection generation"),
    };
}
