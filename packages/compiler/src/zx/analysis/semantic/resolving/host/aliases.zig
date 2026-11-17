const memory = @import("zx").memory;
const Export = @import("zx").ir.Export;

pub const Rows = struct {
    items: []const memory.NamedId,
    pub fn view(self: *const Rows, comptime Aliases: type) Aliases {
        return .{
            .rows = if (self.items.len == 0) null else @ptrCast(&self.items),
            .row_count = self.items.len,
            .names = &.{},
            .ids = &.{},
        };
    }
};

pub fn borrow(values: []const Export) Rows {
    return .{ .items = memory.borrowNamedRows("type_id", values) };
}
