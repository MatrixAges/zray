const std = @import("std");
const frontend = @import("frontend");
const Loaded = frontend.project.artifact.source_link.Loaded;
const memory = @import("zx").memory;
const little_endian = @import("builtin").target.cpu.arch.endian() == .little;

pub fn equal(left: *const Loaded, right: *const Loaded) bool {
    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const allocator = fixed.allocator();
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
    const MemberView = std.meta.Child(@FieldType(std.meta.Child(@FieldType(Input, "members")), "left"));
    const ConstantView = std.meta.Child(@FieldType(std.meta.Child(@FieldType(Input, "constants")), "left"));
    const left_members = frontend.project.FunctionImport.Columns.borrow(left.members);
    const right_members = frontend.project.FunctionImport.Columns.borrow(right.members);
    const left_constants = frontend.ConstantRows.borrow(left.constant_exports);
    const right_constants = frontend.ConstantRows.borrow(right.constant_exports);

    const input: Input = .{
        .members = &.{
            .left = &left_members.view(MemberView),
            .right = &right_members.view(MemberView),
            .shared = left.members.ptr == right.members.ptr,
        },
        .constants = &.{
            .left = &left_constants.view(ConstantView),
            .right = &right_constants.view(ConstantView),
            .shared = left.constant_exports.ptr == right.constant_exports.ptr,
        },
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
