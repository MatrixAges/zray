const std = @import("std");
const memory = @import("zx").memory;
const Object = @import("../state.zig").Object;
const Self = @This();

modules: memory.TextColumn,
writable: memory.ReadColumn,
independent: ?memory.ReadColumn = null,
uniform_independent: bool = false,
count: usize,
pub fn fromRows(objects: []const Object) Self {
    return .{
        .modules = memory.borrowTextColumn("module_name", objects),
        .writable = memory.borrowReadColumn(bool, "writable", objects),
        .independent = memory.borrowReadColumn(bool, "independent", objects),
        .count = objects.len,
    };
}

pub fn fromBindings(modules: []const []const u8, writable: []const bool, independent: bool) Self {
    std.debug.assert(modules.len == writable.len);

    return .{
        .modules = memory.borrowTextSlice(modules),
        .writable = .{ .bytes = std.mem.sliceAsBytes(writable), .count = writable.len, .stride = @sizeOf(bool), .offset = 0 },
        .uniform_independent = independent,
        .count = modules.len,
    };
}

pub fn bind(self: *const Self, comptime View: type) View {
    return .{
        .modules = @ptrCast(&self.modules),
        .writable = @ptrCast(&self.writable),
        .independent = if (self.independent) |*column| @ptrCast(column) else null,
        .uniform_independent = self.uniform_independent,
        .count = self.count,
    };
}
