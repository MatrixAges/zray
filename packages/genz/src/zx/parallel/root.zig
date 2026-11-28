const std = @import("std");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const rows = @import("../construction/publication.zig");
const evaluate = @import("../expressions/evaluate.zig");

pub fn lower(self: *Lower, invocations: @FieldType(ir.StatementRow, "parallel")) Lower.Error!node.Block {
    if (!@import("genz_options").generated_analysis) return self.builder.statements(try @import("root_seed.zig").lower(self, invocations));

    const entry = @import("generated_execute_parallel_statement");
    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());
    const allocator = memory.allocator();
    const arguments = try allocator.alloc(u32, invocations.len);
    const functions = try allocator.alloc(u32, invocations.len);

    defer scratch.deinit();

    for (invocations.values[0..invocations.len], arguments, functions) |expression, *argument, *function| {
        const call = self.program.expression(@fromBackingInt(expression)).value.call;

        argument.* = @backingInt(call.argument);
        function.* = @backingInt(call.function);
    }

    self.uses_parallel = true;
    self.uses_allocator = true;

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .arguments = arguments,
        .functions = functions,
        .symbols = invocations.symbols[0..invocations.len],
        .used = self.used,
        .names = self.names,
    };

    const result = entry.executeIn(allocator, &input) catch |err| return rows.failure(err);

    return rows.unpackSpan(result);
}

pub fn buildParallelWorker(handle: *anyopaque, function_id: u32) Lower.Error!u32 {
    return @backingInt(try @import("worker.zig").lower(evaluate.borrow(handle), @fromBackingInt(function_id)));
}
