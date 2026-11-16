const memory = @import("zx").memory;
const Export = @import("zx").ir.Export;

pub const Rows = []const memory.NamedId;

pub fn borrow(exports: []const Export) Rows {
    return memory.borrowNamedRows("type_id", exports);
}

pub fn view(comptime Row: type, rows: *const Rows) Row {
    return .{ .rows = @ptrCast(rows), .length = rows.len };
}
