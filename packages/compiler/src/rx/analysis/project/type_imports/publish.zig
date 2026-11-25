const std = @import("std");
const zx = @import("zx");
const expressions = @import("frontend").expressions;
const memory = @import("zx").memory;
const entry = @import("generated_rx_publish_type_imports");
const Input = std.meta.Child(entry.Input);
const Qualified = std.meta.Child(@typeInfo(@FieldType(Input, "qualified")).optional.child);
const Values = std.meta.Child(@FieldType(Input, "values"));
const Export = zx.ir.Export;
pub const Target = struct { alias: []const u8, rows: []Export };

const Tail = struct {
    allocator: std.mem.Allocator,
    visible: *expressions.BindingStorage,
    names: [][]const u8 = undefined,
    ids: []zx.ir.TypeId = undefined,
    view: Values = undefined,
    fn open(self: *Tail) void {
        var reserved = self.visible.slice();

        reserved.len = reserved.capacity;
        self.names = reserved.items(.name)[self.visible.len..];
        self.ids = reserved.items(.type_id)[self.visible.len..];
        self.view = .{ .names = @ptrCast(&self.names), .ids = @ptrCast(&self.ids), .capacity = self.ids.len };
    }
};

pub fn append(allocator: std.mem.Allocator, value_allocator: std.mem.Allocator, exports: []const Export, kinds: []const u8, visible: *expressions.BindingStorage, target: ?Target) std.mem.Allocator.Error!void {
    if (exports.len == 0) return;

    const rows = memory.borrowNamedRows("type_id", exports);
    var destination: []memory.NamedId = if (target) |output| memory.borrowNamedRows("type_id", output.rows) else &.{};

    const qualified: Qualified = .{
        .alias = if (target) |output| output.alias else "",
        .rows = @ptrCast(&destination),
    };

    var tail: Tail = .{ .allocator = value_allocator, .visible = visible };

    tail.open();

    entry.executeIn(allocator, &.{
        .rows = @ptrCast(&rows),
        .length = rows.len,
        .kinds = kinds,
        .qualified = if (target != null) &qualified else null,
        .tail = @ptrCast(&tail),
        .values = &tail.view,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
    };
}

pub fn advanceTypeBindingTail(handle: *anyopaque, used: u64, grow: bool) std.mem.Allocator.Error!void {
    const tail: *Tail = @ptrCast(@alignCast(handle));
    tail.visible.len += @intCast(used);

    if (grow) {
        try tail.visible.ensureUnusedCapacity(tail.allocator, 1);

        tail.open();
    }
}
