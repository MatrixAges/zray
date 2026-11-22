const std = @import("std");
const Table = @import("root.zig");
const columns = @import("../columns.zig");
const retained = @import("generated_type_retained_payload");
const first = @import("generated_type_delta_first");
const FirstInput = std.meta.Child(first.Input);
const Offsets = std.meta.Child(@typeInfo(@FieldType(FirstInput, "offsets")).optional.child);

pub fn ends(table: *const Table, count: usize) @import("root.zig").Ends {
    const request: std.meta.Child(retained.Input) = .{
        .kinds = table.kinds,
        .first = table.first,
        .second = table.second,
        .count = count,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const result = columns.invoke(retained.executeValue, scratch.allocator(), &request) catch unreachable;

    return .{ .children = @intCast(result.children), .fields = @intCast(result.fields), .names = @intCast(result.names) };
}

pub fn writeFirst(delta: *const Table, destination: []u32, child_offset: u32, field_offset: u32, name_offset: u32) void {
    const offsets: Offsets = .{ .children = child_offset, .fields = field_offset, .names = name_offset };
    const target = destination;
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    first.executeIn(scratch.allocator(), &FirstInput{
        .kinds = delta.kinds,
        .first = delta.first,
        .target = @ptrCast(&target),
        .offsets = &offsets,
    }) catch unreachable;
}
