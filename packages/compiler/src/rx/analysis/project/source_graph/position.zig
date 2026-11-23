const std = @import("std");
const rx = @import("rx");
const Location = rx.ast.Location;
const unresolved_line = std.math.maxInt(usize);

/// ZX edges retain only a byte offset. XML edges already have coordinates.
pub fn deferred(offset: usize) Location {
    return .{ .offset = offset, .line = unresolved_line, .column = 0 };
}

pub fn imported(offset: usize, discovering: bool) Location {
    return if (discovering) .{ .offset = offset, .line = 1, .column = 1 } else deferred(offset);
}

pub fn locate(position: Location, source: []const u8) Location {
    return if (position.line == unresolved_line) rx.sourceLocation(source, position.offset) else position;
}
