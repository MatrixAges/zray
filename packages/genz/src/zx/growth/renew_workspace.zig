const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Self = @This();

scratch: std.heap.ArenaAllocator,
pub const Request = struct {
    type_id: ir.TypeId,
    roots: []const u32,
};

pub noinline fn run(frame: anytype, comptime Source: type, request: Request, comptime execute: anytype) @typeInfo(@TypeOf(execute)).@"fn".return_type.? {
    const self = frame.lowering;
    const Facts = std.meta.Child(@FieldType(Source, "facts"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), self.program.types);
    const records = zx.columns.view(std.meta.Child(@FieldType(Source, "records")), self.plan.renewals);
    const expressions: *const ir.ExpressionTable = &self.program.expressions;

    const facts: Facts = .{
        .expressions = zx.columns.pointer(@FieldType(Facts, "expressions"), expressions),
        .types = &types,
        .selected = self.state_plan.selected,
        .referenced = self.state_plan.borrowed,
        .roots = request.roots,
        .state_type = @backingInt(request.type_id),
    };

    var workspace: Self = .{ .scratch = .init(self.workspace) };

    defer workspace.scratch.deinit();

    frame.renewal_workspace = &workspace;

    var planning_buffer: [std.heap.page_size_min]u8 = undefined;
    var planning = std.heap.BufferFirstAllocator.init(&planning_buffer, workspace.scratch.allocator());
    const source: Source = .{ .facts = &facts, .records = &records };

    return execute(frame, planning.allocator(), &source);
}
