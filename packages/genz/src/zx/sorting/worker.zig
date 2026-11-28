const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const reuse = @import("../scope/reuse.zig");
const scope = @import("../functions/scope.zig");
const rows = @import("../construction/publication.zig");
const evaluation = @import("../expressions/evaluate.zig");
const Api = evaluation.Api;
const Error = Lower.Error;
pub const Result = struct { declaration: u32, io: bool, process: bool };

pub fn build(self: *Lower, value: ir.Transform, child: node.ExpressionId, errors: ?[]const []const u8) Error!Result {
    var worker = scope.inherit(self, .Sort);

    try scope.reserve(&worker, self.allocator, .Sort);

    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const names = try reuse.saveNames(self, value.parameters, memory.allocator());

    defer names.restore(self);

    const entry = @import("generated_execute_sort_worker");

    const input: std.meta.Child(entry.Input) = .{
        .writer = @ptrCast(self),
        .lower = @ptrCast(self),
        .worker = @ptrCast(&worker),
        .parameters = @import("../../node/view.zig").slice([]const u32, value.parameters),
        .list_type = @backingInt(self.program.expression(value.target).type_id),
        .child = @backingInt(child),
        .body_expr = @backingInt(value.body),
        .output_type = @backingInt(self.program.expression(value.body).type_id),
        .errors = errors,
    };

    const declaration = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return .{ .declaration = declaration, .io = worker.uses_io, .process = worker.uses_process };
}

pub fn bindSortWorkerNames(frame: *anyopaque, parameters: []const u32, names: []const []const u8) void {
    reuse.setNames(evaluation.borrow(frame), parameters, names);
}

pub fn registerSortParameters(handle: *anyopaque, parameters: []const u32) Error!void {
    const worker = evaluation.borrow(handle);

    return @import("../state_value/locals.zig").registerOwned(worker, parameters);
}

pub fn readSortOperand(allocator: std.mem.Allocator, handle: *anyopaque, list_type: u32, value: u32) Error!*const Api.SortOperand {
    const worker = evaluation.borrow(handle);
    var helper = worker.builder.statementSequence(allocator);

    defer helper.deinit();

    const element = try @import("../state_value/elements.zig").read(worker, &helper, @fromBackingInt(list_type), @fromBackingInt(value));
    const span = try helper.block(worker.allocator);
    const result = try allocator.create(Api.SortOperand);

    result.* = .{ .value = @backingInt(element), .span = rows.packSpan(span) };

    return result;
}
