const memory = @import("zx").memory;
const Initializer = @import("../modules.zig").StoreInitializer;
const Self = @This();

keys: memory.TextColumn,
modules: memory.TextColumn,
types: memory.TextColumn,
count: usize,
pub fn init(rows: []const Initializer) Self {
    return .{
        .keys = memory.borrowTextColumn("identity", rows),
        .modules = memory.borrowTextColumn("module_name", rows),
        .types = memory.borrowTextColumn("type_name", rows),
        .count = rows.len,
    };
}

pub fn input(self: *const Self, comptime Target: type) Target {
    return .{
        .keys = @ptrCast(&self.keys),
        .modules = @ptrCast(&self.modules),
        .types = @ptrCast(&self.types),
        .count = self.count,
    };
}
