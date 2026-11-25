const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const rows = @import("../construction/publication.zig");
const evaluate = @import("../expressions/evaluate.zig");

pub fn lower(self: *Lower, id: ir.FunctionId) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("worker_seed.zig").lower(self, id);

    const entry = @import("generated_execute_parallel_worker");
    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());
    var origin: rows.OriginBuffer = .{};
    const index = @backingInt(id);

    defer scratch.deinit();

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .function_id = index,
        .input_type = self.program.functions.input_types[index],
        .output_type = self.program.functions.output_types[index],
    };

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return @fromBackingInt(result);
}

pub fn parallelWorkerCallee(handle: *anyopaque, index: u32) Lower.Error!u32 {
    return @backingInt(try evaluate.borrow(handle).functionReference(@fromBackingInt(index)));
}
