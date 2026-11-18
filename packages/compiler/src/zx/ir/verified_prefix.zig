const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const structure = @import("function_structure.zig");

pub fn count(table: ir.FunctionTable, verified: ir.FunctionTable) usize {
    const limit = @min(table.count(), verified.count());

    if (limit == 0) return 0;
    if (!structure.valid(&table) or !structure.valid(&verified)) return 0;

    inline for (@typeInfo(ir.FunctionTable).@"struct".field_names) |name| {
        if (@field(table, name).ptr != @field(verified, name).ptr) break;
    } else return limit;

    // Bound work by the first changed row even when a later column contains the mismatch.
    var first: usize = 0;

    while (first < limit) {
        const end = first + @min(limit - first, @max(first, 1));
        const matched = matching(&table, &verified, first, end, false);

        if (matched != end) return matched;

        first = end;
    }

    return limit;
}

/// Both tables have passed structural validation, including the lengths of their columns.
pub fn covers(table: *const ir.FunctionTable, prefix: *const ir.FunctionTable) bool {
    return matching(table, prefix, 0, prefix.count(), true) == prefix.count();
}

fn matching(table: *const ir.FunctionTable, prefix: *const ir.FunctionTable, first: usize, end: usize, comptime all: bool) usize {
    var limit = end;

    inline for (@typeInfo(ir.FunctionTable).@"struct".field_names) |name| {
        const values = @field(table, name);
        const previous = @field(prefix, name);

        if (limit == first) return first;

        if (values.ptr != previous.ptr) {
            limit = first + compared(values[first..limit], previous[first..limit]);

            if (all and limit < end) return limit;
        }
    }

    return limit;
}

fn compared(left: anytype, right: @TypeOf(left)) usize {
    if (comptime !@import("parser_options").generated_parser) {
        for (left, right, 0..) |a, b, index| if (!std.meta.eql(a, b)) return index;

        return left.len;
    }

    const Element = std.meta.Elem(@TypeOf(left));

    if (Element == ?u32) return run(@import("generated_function_prefix_ids"), .{ .left = left, .right = right });

    // Nested slices are compared solely by address and element count. Their contents stay untouched.
    if (comptime @typeInfo(Element) == .optional) {
        const T = @typeInfo(Element).optional.child;

        if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .slice) @compileError("Unsupported optional column");

        const a: []const ?[]const u8 = @ptrCast(left);
        const b: []const ?[]const u8 = @ptrCast(right);

        return run(@import("generated_function_prefix_optional_views"), .{ .left = a, .right = b });
    }

    if (comptime @typeInfo(Element) == .pointer and @typeInfo(Element).pointer.size == .slice) {
        const a: []const []const u8 = @ptrCast(left);
        const b: []const []const u8 = @ptrCast(right);

        return run(@import("generated_function_prefix_views"), .{ .left = a, .right = b });
    }

    const mask: u64 = comptime switch (@typeInfo(Element)) {
        .bool, .@"enum" => if (@sizeOf(Element) == 1) std.math.maxInt(@Int(.unsigned, @bitSizeOf(Element))) else @compileError("Unsupported tag size"),
        .int, .pointer => if (@bitSizeOf(Element) == 8 * @sizeOf(Element)) std.math.maxInt(u8) else @compileError("Unsupported padded column"),
        else => @compileError("Unsupported function column"),
    };

    return run(@import("generated_function_prefix_bytes"), .{ .left = std.mem.sliceAsBytes(left), .right = std.mem.sliceAsBytes(right), .width = @as(u64, @sizeOf(Element)), .mask = mask });
}

inline fn run(comptime rule: type, input: std.meta.Child(rule.Input)) usize {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return @intCast(zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable);
}
