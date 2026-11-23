const std = @import("std");
const ir = @import("zx").ir;
const Source = @import("frontend").project.artifact.source_link;
const Self = @This();
const Surface = Source.Surface;
pub const Destination = struct { value: Source.Output, present: ?*bool = null };
const Row = struct { surface: Surface, function: ?u32, present: bool };

surfaces: []Surface = &.{},
functions: []?u32 = &.{},
present: []bool = &.{},
pub fn init(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Self {
    var storage: std.MultiArrayList(Row) = .empty;

    try storage.setCapacity(allocator, count);

    storage.len = count;

    const slice = storage.slice();
    const present = slice.items(.present);

    @memset(present, false);

    return .{ .surfaces = slice.items(.surface), .functions = slice.items(.function), .present = present };
}

pub fn get(self: Self, index: usize) ?*const Surface {
    return if (self.present[index]) self.getAssumePresent(index) else null;
}

pub fn getAssumePresent(self: Self, index: usize) *const Surface {
    std.debug.assert(self.present[index]);

    return &self.surfaces[index];
}

pub fn function(self: Self, index: usize) ?ir.FunctionId {
    return if (self.functions[index]) |id| @fromBackingInt(id) else null;
}

pub fn namedFunction(self: Self, index: usize, name: []const u8) ?ir.FunctionId {
    if (!self.present[index]) return null;

    return @import("../../call/named.zig").memberId(self.surfaces[index].members, name);
}

pub fn destination(self: Self, index: usize) Destination {
    return .{
        .value = .{ .surface = &self.surfaces[index], .function = &self.functions[index] },
        .present = &self.present[index],
    };
}

pub fn retain(self: Self, earlier: Self, index: usize) void {
    const present = earlier.present[index];

    if (present) {
        self.surfaces[index] = earlier.surfaces[index];
        self.functions[index] = earlier.functions[index];
    }

    self.present[index] = present;
}
