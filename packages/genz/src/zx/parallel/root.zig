const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const rows = @import("../construction/publication.zig");
const evaluate = @import("../expressions/evaluate.zig");
const Record = evaluate.Api.ParallelRecord;

const Records = struct {
    allocator: std.mem.Allocator,
    references: []*const Record = &.{},
    values: []Record = &.{},
    fn borrow(handle: *const anyopaque) *Records {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn lower(self: *Lower, invocations: @FieldType(ir.StatementRow, "parallel")) Lower.Error!node.Block {
    if (!@import("genz_options").generated_analysis) return self.builder.statements(try @import("root_seed.zig").lower(self, invocations));

    const entry = @import("generated_execute_parallel_statement");
    var scratch: std.heap.ArenaAllocator = .init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory: std.heap.BufferFirstAllocator = .init(&buffer, scratch.allocator());
    var origin: rows.OriginBuffer = .{};
    var records: Records = .{ .allocator = memory.allocator() };

    defer scratch.deinit();

    const input: std.meta.Child(entry.Input) = .{
        .frame = @ptrCast(self),
        .writer = @ptrCast(self),
        .origin = @ptrCast(&origin),
        .expressions = invocations.values[0..invocations.len],
        .symbols = invocations.symbols[0..invocations.len],
        .records = @ptrCast(&records),
        .used = self.used,
        .names = self.names,
    };

    const result = entry.executeIn(memory.allocator(), &input) catch |err| return rows.failure(err);

    return rows.unpackSpan(result);
}

pub fn markParallelStatement(handle: *const anyopaque) void {
    const self = evaluate.borrow(handle);

    self.uses_parallel = true;
    self.uses_allocator = true;
}

pub fn lowerParallelArgument(handle: *const anyopaque, expression: u32) Lower.Error!u32 {
    const self = evaluate.borrow(handle);
    const call = self.program.expression(@fromBackingInt(expression)).value.call;

    return @backingInt(try self.expr(call.argument));
}

pub fn buildParallelWorker(handle: *const anyopaque, expression: u32) Lower.Error!u32 {
    const self = evaluate.borrow(handle);
    const call = self.program.expression(@fromBackingInt(expression)).value.call;

    return @backingInt(try @import("worker.zig").lower(self, call.function));
}

pub fn reserveParallelRecords(handle: *const anyopaque, count: u64) Lower.Error!void {
    const records = Records.borrow(handle);
    records.references = try records.allocator.alloc(*const Record, @intCast(count));
    records.values = try records.allocator.alloc(Record, @intCast(count));
}

pub fn storeParallelRecord(
    handle: *const anyopaque,
    row: u64,
    argument: u32,
    worker_type: u32,
    type_name: []const u8,
    input_name: []const u8,
    worker_name: []const u8,
    thread_name: []const u8,
    symbol: ?u32,
) void {
    const records = Records.borrow(handle);
    const index: usize = @intCast(row);

    records.values[index] = .{
        .argument = argument,
        .worker_type = worker_type,
        .type_name = type_name,
        .input_name = input_name,
        .worker_name = worker_name,
        .thread_name = thread_name,
        .symbol = symbol,
    };

    records.references[index] = &records.values[index];
}

pub fn readParallelRecords(handle: *const anyopaque) []const *const Record {
    return Records.borrow(handle).references;
}
