const std = @import("std");
const Object = @import("../state.zig").Object;
const ObjectColumns = @import("objects.zig");

pub fn writable(objects: []const Object) bool {
    if (@import("genz_options").generated_analysis) return policy(objects) != .ReadOnly;
    for (objects) |object| if (object.writable) return true;

    return false;
}

pub fn reclaimable(objects: []const Object) bool {
    if (@import("genz_options").generated_analysis) return policy(objects) == .Independent;
    for (objects) |object| if (object.writable and !object.independent) return false;

    return writable(objects);
}

fn policy(objects: []const Object) @typeInfo(@typeInfo(@TypeOf(@import("generated_store_lifecycle_policy").executeValue)).@"fn".return_type.?).error_union.payload {
    const entry = @import("generated_store_lifecycle_policy");
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    const columns = ObjectColumns.fromRows(objects);
    const view = columns.bind(std.meta.Child(@FieldType(Input, "objects")));

    const input: Input = .{
        .objects = &view,
    };

    var memory = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeValue(memory.allocator(), if (indirect) &input else input) catch unreachable;
}
