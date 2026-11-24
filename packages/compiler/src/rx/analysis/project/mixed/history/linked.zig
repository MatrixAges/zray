const std = @import("std");
const frontend = @import("frontend");
const Finished = @import("../finished.zig");
const Surface = frontend.project.artifact.source_link.Surface;
const memory = @import("zx").memory;
const little_endian = @import("builtin").target.cpu.arch.endian() == .little;

pub const Link = struct {
    earlier: *const Finished,
    current: *const Finished,
    row: usize,
};

pub fn matchHistoryLink(handle: *const anyopaque) bool {
    const pair: *const Link = @ptrCast(@alignCast(handle));
    const current = pair.current;
    const previous = pair.earlier;
    const row = pair.row;
    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const allocator = fixed.allocator();
    const link = @import("generated_rx_mixed_history_link");
    const Input = std.meta.Child(link.Input);
    const Port = std.meta.Child(@FieldType(std.meta.Child(@FieldType(Input, "ports")), "left"));
    const Initializer = std.meta.Elem(@FieldType(Surface, "store_initializers"));
    const left = current.getAssumePresent(row);
    const right = previous.getAssumePresent(row);
    const left_exports = memory.borrowNamedRows("type_id", left.exports);
    const right_exports = memory.borrowNamedRows("type_id", right.exports);
    const left_port = port(Port, left, current.functions[row]);
    const right_port = port(Port, right, previous.functions[row]);
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
            .left = @ptrCast(&left_exports),
            .right = @ptrCast(&right_exports),
            .left_count = left_exports.len,
            .right_count = right_exports.len,
            .shared = left.exports.ptr == right.exports.ptr,
        },
        .initializers = &.{
            .left = &.{ .data = std.mem.sliceAsBytes(left.store_initializers), .count = left.store_initializers.len },
            .right = &.{ .data = std.mem.sliceAsBytes(right.store_initializers), .count = right.store_initializers.len },
            .stride = @sizeOf(Initializer),
            .identity_offset = @offsetOf(Initializer, "identity"),
            .function_id = @offsetOf(Initializer, "function"),
            .schema_version = @offsetOf(Initializer, "schema_version"),
            .little_endian = little_endian,
            .shared = left.store_initializers.ptr == right.store_initializers.ptr,
            .identity = false,
            .function_prefix = null,
        },
    };

    return link.executeValue(allocator, &input) catch unreachable;
}

fn port(comptime Port: type, value: *const Surface, function: ?u32) Port {
    return .{
        .function = function,
        .input_type = @backingInt(value.input_type),
        .output_type = @backingInt(value.output_type),
    };
}
