const std = @import("std");

pub const Lengths = []const *usize;

pub fn borrow(storage: anytype) [@typeInfo(std.meta.Child(@TypeOf(storage))).@"struct".field_names.len]*usize {
    const fields = @typeInfo(std.meta.Child(@TypeOf(storage))).@"struct".field_names;
    var lengths: [fields.len]*usize = undefined;

    inline for (fields, &lengths) |name, *length| {
        length.* = &@field(storage, name).items.len;
    }

    return lengths;
}

fn view(target: *const anyopaque) Lengths {
    const lengths: *const Lengths = @ptrCast(@alignCast(target));

    return lengths.*;
}

pub inline fn count(target: *const anyopaque) u64 {
    return view(target).len;
}

pub inline fn read(target: *const anyopaque, index: u64) u64 {
    return view(target)[@intCast(index)].*;
}

pub inline fn advance(target: *const anyopaque, index: u64, added: u64) void {
    view(target)[@intCast(index)].* += @intCast(added);
}

pub inline fn shrink(target: *const anyopaque, index: u64, limit: u64) void {
    const length = view(target)[@intCast(index)];

    std.debug.assert(limit <= length.*);

    length.* = @intCast(limit);
}
