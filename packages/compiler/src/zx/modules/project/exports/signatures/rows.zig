const std = @import("std");
const Member = @import("../../../source_signature.zig").Member;

pub fn commit(allocator: std.mem.Allocator, target: []Member, source: []const Member, change: anytype) std.mem.Allocator.Error!void {
    const row: usize = @intCast(change.row);

    switch (change.action) {
        .Reserve => unreachable,
        .Forwarded => @memcpy(target[row..][0..source.len], source),
        .Reexport => {
            var member = source[@intCast(change.source_row)];

            member.name = try allocator.dupe(u8, change.name);
            target[row] = member;
        },
        .Value => {
            const name = if (change.own_name) try allocator.dupe(u8, change.name) else change.name;

            target[row] = .{
                .name = name,
                .kind = @fromBackingInt(change.kind),
                .ports = .{ .input_type = @fromBackingInt(change.input_type), .output_type = @fromBackingInt(change.output_type) },
                .has_store = change.has_store,
            };
        },
    }
}
