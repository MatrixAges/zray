const std = @import("std");
const zx = @import("zx");
const entry = @import("generated_uniqueness_memo_replay_key");
const Input = std.meta.Child(entry.Input);

pub fn build(kind: u8, identity: *const [32]u8, state: []const u8) [32]u8 {
    var hash: zx.Sha256 = undefined;
    const storage = zx.Sha256State{ .value = &hash };

    const input: Input = .{
        .kind = @fromBackingInt(@intCast(kind)),
        .hash = @ptrCast(&storage),
        .identity = identity,
        .state = state,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

    return hash.finalResult();
}
