const std = @import("std");
const generated = @import("parser_options").generated_parser;
const claim = if (generated) @import("generated_library_index_claim").executeState else void;
const Parameter = if (generated) @typeInfo(@TypeOf(claim)).@"fn".param_types[1].? else void;
const Input = if (generated and @typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
const State = if (generated) @FieldType(Input, "index") else std.StringHashMapUnmanaged(u32);
const Self = @This();

state: State = if (generated) .{
    .keys = .{ .items = &.{}, .storage = .plain },
    .values = .{ .items = &.{}, .storage = .plain },
    .buckets = .{ .items = &.{}, .storage = .plain },
} else .empty,
pub fn register(self: *Self, allocator: std.mem.Allocator, key: []const u8, row: usize) std.mem.Allocator.Error!?u32 {
    const id = std.math.cast(u32, row) orelse return error.OutOfMemory;

    if (comptime !generated) {
        const entry = try self.state.getOrPut(allocator, key);

        if (entry.found_existing) return entry.value_ptr.*;

        entry.value_ptr.* = id;

        return null;
    }

    const input: Input = .{
        .index = self.state,
        .key = .{ .items = key, .storage = .plain },
        .value = id,
    };

    const result = claim(allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    self.state = result.index;

    return result.previous;
}
