const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const strings = @import("native.zig").strings;
const Error = std.mem.Allocator.Error || error{InvalidModule};
const generated = @import("generated_compiled_function_batch");
const Input = @typeInfo(@TypeOf(generated.executeState)).@"fn".param_types[1].?;
const Columns = @FieldType(Input, "target");

pub const Context = struct {
    types: []const u32,
    natives: []const u32,
    first: usize,
    instance: []const u8,
};

pub fn append(allocator: std.mem.Allocator, functions: *ir.FunctionStorage, source: ir.FunctionTable, context: Context) Error!void {
    const count = source.count();

    if (count == 0) return;
    try functions.reserve(allocator, count);

    const tails = functions.reservedTail(count);
    var completed: [1]u64 = .{0};
    const progress: []u64 = &completed;

    defer publish(functions, source, @intCast(completed[0]));

    const input: Input = .{
        .source = stateColumns(@FieldType(Input, "source"), source, false),
        .target = stateColumns(Columns, tails, true),
        .mapping = stateColumns(@FieldType(Input, "mapping"), context, false),
        .first = context.first,
        .instance = context.instance,
        .progress = @ptrCast(&progress),
    };

    const output = generated.executeState(allocator, input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    std.debug.assert(completed[0] == count);

    inline for (@typeInfo(Columns).@"struct".field_names) |name| {
        if (comptime @hasField(ir.FunctionTable, name)) {
            std.debug.assert(@field(output, name).items.ptr == @field(input.target, name).items.ptr);
        }
    }
}

fn stateColumns(comptime Layout: type, source: anytype, comptime owns_tail: bool) Layout {
    var result: Layout = undefined;

    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "zx_origin")) {
            @field(result, name) = null;
        } else {
            const Field = @FieldType(Layout, name);

            @field(result, name) = .{
                .items = zx.columns.slice(@FieldType(Field, "items"), @field(source, name)),
                .storage = if (owns_tail) .owned else .plain,
            };
        }
    }

    return result;
}

fn publish(functions: *ir.FunctionStorage, source: ir.FunctionTable, count: usize) void {
    if (count == 0) return;

    inline for (@typeInfo(ir.FunctionTable).@"struct".field_names) |name| {
        if (comptime !@hasField(Columns, name)) {
            @memcpy(@field(functions, name).unusedCapacitySlice()[0..count], @field(source, name)[0..count]);
        }
    }

    functions.commitTail(count);
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
