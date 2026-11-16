const std = @import("std");
const frontend = @import("frontend");
const Loaded = frontend.project.artifact.source_link.Loaded;
const memory = @import("zxc_standard").memory;
const little_endian = @import("builtin").target.cpu.arch.endian() == .little;

pub fn equal(left: *const Loaded, right: *const Loaded) bool {
    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const allocator = fixed.allocator();

    if (!sameLink(allocator, left, right)) return false;
    if (left.members.len != right.members.len or left.constant_exports.len != right.constant_exports.len) return false;

    if (left.members.ptr != right.members.ptr) {
        const entry = @import("generated_rx_mixed_history_member");
        const Pair = std.meta.Child(entry.Input);
        const Member = std.meta.Child(@FieldType(Pair, "left"));

        for (left.members, right.members) |*x, *y| {
            const l = x.borrow(Member);
            const r = y.borrow(Member);

            if (!(entry.executeIn(allocator, &.{ .left = &l, .right = &r }) catch unreachable)) return false;
        }
    }

    if (left.constant_exports.ptr != right.constant_exports.ptr) {
        const entry = @import("generated_rx_mixed_history_constant");
        const Pair = std.meta.Child(entry.Input);
        const Constant = std.meta.Child(@FieldType(Pair, "left"));
        const Literal = std.meta.Child(@FieldType(Constant, "value"));

        for (left.constant_exports, right.constant_exports) |x, y| {
            const l = frontend.borrowConstant(Literal, x);
            const r = frontend.borrowConstant(Literal, y);
            const a_constant: Constant = .{ .name = x.name, .value = &l };
            const b_constant: Constant = .{ .name = y.name, .value = &r };

            if (!(entry.executeIn(allocator, &.{ .left = &a_constant, .right = &b_constant }) catch unreachable)) return false;
        }
    }

    return true;
}

fn sameLink(allocator: std.mem.Allocator, left: *const Loaded, right: *const Loaded) bool {
    const link = @import("generated_rx_mixed_history_link");
    const Input = std.meta.Child(link.Input);
    const Port = std.meta.Child(@FieldType(std.meta.Child(@FieldType(Input, "ports")), "left"));
    const Row = std.meta.Child(@FieldType(std.meta.Child(@FieldType(Input, "exports")), "left"));
    const Export = std.meta.Elem(@FieldType(Loaded, "exports"));
    const Initializer = std.meta.Elem(@FieldType(Loaded, "store_initializers"));
    const left_names = memory.borrowTextColumn("name", left.exports);
    const right_names = memory.borrowTextColumn("name", right.exports);
    const left_identities = memory.borrowTextColumn("identity", left.store_initializers);
    const right_identities = memory.borrowTextColumn("identity", right.store_initializers);
    const left_port = port(Port, left);
    const right_port = port(Port, right);
    const left_exports = rows(Row, &left_names, left.exports);
    const right_exports = rows(Row, &right_names, right.exports);
    const left_initializers = rows(Row, &left_identities, left.store_initializers);
    const right_initializers = rows(Row, &right_identities, right.store_initializers);

    const input: Input = .{
        .ports = &.{ .left = &left_port, .right = &right_port },
        .exports = &.{
            .left = &left_exports,
            .right = &right_exports,
            .stride = @sizeOf(Export),
            .type_id = offset(Export, "type_id"),
            .little_endian = little_endian,
            .shared = left.exports.ptr == right.exports.ptr,
        },
        .initializers = &.{
            .left = &left_initializers,
            .right = &right_initializers,
            .stride = @sizeOf(Initializer),
            .function_id = offset(Initializer, "function"),
            .schema_version = offset(Initializer, "schema_version"),
            .little_endian = little_endian,
            .shared = left.store_initializers.ptr == right.store_initializers.ptr,
        },
    };

    return link.executeValue(allocator, &input) catch unreachable;
}

fn rows(comptime Row: type, names: *const memory.TextColumn, source: anytype) Row {
    return .{ .names = @ptrCast(names), .data = std.mem.sliceAsBytes(source), .count = source.len };
}

fn offset(comptime Row: type, comptime field: []const u8) usize {
    const Value = @FieldType(Row, field);
    const Raw = if (@typeInfo(Value) == .@"enum") @typeInfo(Value).@"enum".tag_type else Value;

    comptime if (Raw != u32) @compileError("History comparison requires a u32-backed row field");

    return @offsetOf(Row, field);
}

fn port(comptime Port: type, value: *const Loaded) Port {
    return .{
        .function = if (value.function) |id| @backingInt(id) else null,
        .input_type = @backingInt(value.input_type),
        .output_type = @backingInt(value.output_type),
    };
}
