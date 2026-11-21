const std = @import("std");
const zx = @import("zx");
const entry = @import("generated_uniqueness_memo_replay_key");
const Input = std.meta.Child(entry.Input);

pub fn probe(kind: u8, identity: *const [32]u8, state: []const u8, table: anytype, digest: *[32]u8) ?u32 {
    const Table = std.meta.Child(@FieldType(Input, "table"));
    const target: []u8 = digest;
    const used = table.useColumn();

    const input: Input = .{
        .kind = @fromBackingInt(@intCast(kind)),
        .digest = @ptrCast(&target),
        .table = &table.probe(Table, &used),
        .identity = identity,
        .state = state,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;
}
