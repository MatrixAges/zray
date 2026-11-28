const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const evaluation = @import("../expressions/evaluate.zig");
const rows = @import("../construction/publication.zig");
const Api = evaluation.Api;
const lists = @import("../state_value/list.zig");
const worker = @import("worker.zig");
const Error = Lower.Error;

pub fn lower(self: *Lower, id: ir.ExprId, value: ir.Transform) Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("root_seed.zig").lower(self, id, value);

    const entry = @import("generated_execute_sort");
    const Input = std.meta.Child(entry.Input);
    const Elements = std.meta.Child(@FieldType(Input, "elements"));
    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const list_type = self.program.expression(value.target).type_id;
    const errors = try @import("../error_effects.zig").expression(self, id);
    var body = self.builder.statementSequence(self.workspace);

    defer body.deinit();

    var types: std.meta.Child(@FieldType(Elements, "types")) = undefined;
    const elements = @import("../state_value/element_emission.zig").borrowSource(Elements, self, &types);

    const input: Input = .{
        .id = @backingInt(id),
        .writer = @ptrCast(self),
        .lower = @ptrCast(self),
        .body = @ptrCast(&body),
        .target = @backingInt(value.target),
        .environment = @backingInt(value.initial.?),
        .list_type = @backingInt(list_type),
        .elements = &elements,
        .selected = lists.selected(self, list_type),
        .reusable = self.plan.get(id).in_place,
        .errors = errors,
    };

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return @fromBackingInt(result);
}

pub fn buildSortComparator(allocator: std.mem.Allocator, frame: *anyopaque, id: u32, child: u32, errors: ?[]const []const u8) Error!*const Api.SortComparator {
    const lowering = evaluation.borrow(frame);
    const transform = lowering.program.expression(@fromBackingInt(id)).value.transform;
    const result = try worker.build(lowering, transform, @fromBackingInt(child), errors);
    const comparator = try allocator.create(Api.SortComparator);
    comparator.* = .{ .declaration = result.declaration, .io = result.io, .process = result.process };

    return comparator;
}
