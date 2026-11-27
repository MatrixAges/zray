const std = @import("std");
const Memo = @import("../memo.zig");
const publication = @import("table/publication.zig");

pub fn Frame(comptime kind: Memo.Kind, comptime Target: type) type {
    return struct {
        const Self = @This();

        table: publication.Write(@FieldType(Memo, @tagName(kind))),
        value: Memo.Result(kind),
        target: Target,
        pub fn open(self: *Self, memo: *Memo) void {
            self.table.open(&@field(memo, @tagName(kind)), memo.arena.child_allocator, &memo.changed, &memo.key, std.mem.asBytes(&self.value));

            self.target = self.table.view(Target);
        }
    };
}
