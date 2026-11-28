const std = @import("std");
const zx = @import("zx");
const Graph = @import("../graph.zig");
const Value = @import("../terms.zig").Value;
const entry = @import("generated_select_symbolic_value");

pub fn select(graph: *Graph, program: *const zx.ir.Program, type_id: zx.ir.TypeId, condition: []const u8, yes: *const Value, no: *const Value, span: zx.Span) zx.Error!Value {
    const Request = std.meta.Child(entry.Input);
    const types = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Request, "types")), program.types);
    const layout = Value.layout(std.meta.Child(@FieldType(Request, "layout")));
    var arena = std.heap.ArenaAllocator.init(graph.allocator);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const allocator = scratch.allocator();

    const input: Request = .{
        .types = &types,
        .type_id = @backingInt(type_id),
        .condition = condition,
        .yes = std.mem.asBytes(yes),
        .no = std.mem.asBytes(no),
        .layout = &layout,
        .destination = null,
        .steps = null,
    };

    const plan = zx.columns.invoke(entry.executeIn, allocator, &input) catch |err| return @import("../execution/context.zig").failure(err);
    const targets = try allocator.alloc([]Value, plan.steps.len);
    var result: Value = undefined;

    for (plan.steps, targets) |step, *destination| {
        const place = step.destination;
        const target = if (place.parent) |parent| &targets[@intCast(parent)][@intCast(place.member)] else &result;

        destination.* = &.{};

        target.* = switch (step.action) {
            .Text => text: {
                const term = if (step.transient.?) try graph.allocator.dupe(u8, step.text.?) else step.text.?;

                break :text try graph.retain(program.*, @fromBackingInt(step.type_id), .{ .scalar = term }, span);
            },
            .Reuse => @as(*const Value, @ptrCast(@alignCast(step.source.?.ptr))).*,
            .Allocate => fields: {
                const items = try graph.allocator.alloc(Value, @intCast(step.count));

                destination.* = items;

                break :fields .{ .fields = items };
            },
        };
    }

    if (!plan.valid) return error.InvalidSource;

    return result;
}
