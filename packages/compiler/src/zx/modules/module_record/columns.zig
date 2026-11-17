const memory = @import("zx").memory;
const Record = @import("../module_record.zig");
const Self = @This();

specifier: memory.TextColumn,
identity: memory.ReadColumn,
target_kind: memory.ReadColumn,
pub fn borrow(items: []const Record.Import) Self {
    return .{
        .specifier = memory.borrowTextColumn("specifier", items),
        .identity = memory.borrowReadColumn(?[]const u8, "identity", items),
        .target_kind = memory.borrowNestedColumn(Record.Target.Kind, &.{ "target", "kind" }, items),
    };
}

pub fn view(self: *const Self, comptime Header: type) Header {
    return .{
        .specifier = @ptrCast(&self.specifier),
        .identity = @ptrCast(&self.identity),
        .target_kind = @ptrCast(&self.target_kind),
        .count = self.specifier.count,
        .source_kind = @intFromEnum(Record.Target.Kind.source),
        .native_kind = @intFromEnum(Record.Target.Kind.native),
        .compiled_kind = @intFromEnum(Record.Target.Kind.compiled),
    };
}
