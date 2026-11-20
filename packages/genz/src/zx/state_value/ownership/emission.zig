const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const apply = @import("../../construction/apply.zig");

pub fn clear(self: *Lower, body: *std.ArrayList(node.Statement), id: ir.ExprId, type_id: ir.TypeId, value: node.ExpressionId, slot: u32) Lower.Error!void {
    const planner = @import("generated_ownership_clear_plan");
    const Request = std.meta.Child(planner.Input);
    const Query = std.meta.Child(@FieldType(Request, "source"));
    const Facts = std.meta.Child(@FieldType(Query, "facts"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), self.program.types);

    const facts: Facts = .{
        .types = &types,
        .selected = self.state_plan.selected,
        .counts = self.slot_counts,
        .first = self.plan.slot_first,
        .transfers = self.plan.transfers,
    };

    const query: Query = .{
        .facts = &facts,
        .node = @backingInt(id),
        .type_id = @backingInt(type_id),
        .slot = slot,
    };

    const request: Request = .{
        .source = &query,
        .referenced = self.state_plan.borrowed,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const plan = planner.executeIn(buffered.allocator(), &request) catch |err| return failure(err);

    if (plan.kinds.len == 0) return;

    const layouts = try resolveLayouts(self, buffered.allocator(), plan.references);
    const emitter = @import("generated_ownership_clear");
    const Input = std.meta.Child(emitter.Input);
    const ast = zx.columns.view(std.meta.Child(@FieldType(Input, "ast")), @import("../list_emission.zig").borrow(self));

    const input: Input = .{
        .plan = plan,
        .layouts = layouts,
        .ast = &ast,
        .value = @backingInt(value),
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .serial = self.serial,
    };

    const output = emitter.executeIn(buffered.allocator(), &input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    try apply.expressions(self, output);

    const storage = @import("../../../node/view.zig").join(output.storage.*, output.variables.*);
    const statements = @import("../../../node/import_statements.zig");

    statements.appendSelected(self.allocator, &self.reference_storage, &storage) catch |err| return imported(err);
    @import("../../../node/import_selected.zig").append(self.allocator, &self.builder.nodes.statements, output.statements) catch |err| return imported(err);

    statements.appendSelected(self.allocator, body, output.body) catch |err| return imported(err);

    self.serial = @intCast(output.serial);
}

pub fn resolveLayouts(self: *Lower, temporary: std.mem.Allocator, references: []const u32) Lower.Error![]const u32 {
    const types = @import("../../types.zig");
    const layouts = try temporary.alloc(u32, references.len);

    for (references, layouts) |type_id, *layout| {
        layout.* = @backingInt(try types.get(self, self.state_layouts, @fromBackingInt(type_id)));
    }

    return layouts;
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}

fn imported(err: @import("../../../node/import_rows.zig").Error) Lower.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => @panic("invalid selected AST rows"),
    };
}
