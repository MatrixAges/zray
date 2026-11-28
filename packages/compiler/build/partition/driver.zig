const std = @import("std");
const entry = @import("partition_rules").partition_objects;
const Store = std.meta.Child(@FieldType(entry.zx_pending, "store_0"));
pub const Input = entry.Input;

const Host = struct {
    store_0: *Store,
    pub fn commit(self: *Host, pending: entry.zx_pending) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

pub fn execute(allocator: std.mem.Allocator, io: std.Io, input: Input) !bool {
    const initial: std.meta.Child(Store) = .{ .valid = &.{} };
    var store: Store = &initial;
    var host: Host = .{ .store_0 = &store };

    return entry.executeIn(allocator, input, &host, io);
}
