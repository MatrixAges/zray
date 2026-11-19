const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const strings = @import("native.zig").strings;
const Error = std.mem.Allocator.Error || error{InvalidModule};
const columns = @import("../../artifact/materializing/publication/columns.zig");
const generated = @import("generated_compiled_function_batch");
const Input = @typeInfo(@TypeOf(generated.executeState)).@"fn".param_types[1].?;
const Columns = @FieldType(Input, "target");

pub const Context = struct {
    types: []const u32,
    natives: []const u32,
    first: usize,
    instance: []const u8,
};

pub fn appendReserved(allocator: std.mem.Allocator, functions: *ir.FunctionStorage, source: ir.FunctionTable, context: Context) Error!void {
    const count = source.count();

    if (count == 0) return;

    const tails = functions.reservedTail(count);
    var completed: [1]u64 = .{0};
    const progress: []u64 = &completed;
    const length_slots = zx.memory.borrowColumnLengths(functions);
    const lengths: zx.memory.ColumnLengths = &length_slots;

    const input: Input = .{
        .source = columns.borrow(@FieldType(Input, "source"), source, false),
        .target = columns.borrow(Columns, tails, true),
        .mapping = columns.borrow(@FieldType(Input, "mapping"), context, false),
        .first = context.first,
        .instance = context.instance,
        .progress = @ptrCast(&progress),
        .lengths = @ptrCast(&lengths),
    };

    const output = generated.executeState(allocator, input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    switch (output.status) {
        .Exhausted => return error.OutOfMemory,
        .Invalid => return error.InvalidModule,
        .Complete => columns.checkBorrow(input.target, output.columns.?),
    }

    std.debug.assert(completed[0] == count);
}

pub fn copyExternalDetails(allocator: std.mem.Allocator, source: ir.External) std.mem.Allocator.Error!ir.External {
    var result = source;

    result.errors = if (source.errors) |errors| try strings(allocator, errors) else null;

    if (source.input) |input| {
        const names = try allocator.alloc(?[]const u8, input.names.len);

        for (input.names, names) |name, *owned| owned.* = if (name) |text| try allocator.dupe(u8, text) else null;

        result.input = .{ .names = names };
    }

    return result;
}
