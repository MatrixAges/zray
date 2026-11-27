const std = @import("std");
const Member = @import("../../../source_signature.zig").Member;
const typedRows = @import("../publication/rows.zig").typedRows;

pub fn commit(allocator: std.mem.Allocator, target: []Member, change: anytype) std.mem.Allocator.Error!void {
    const row: usize = @intCast(change.row);

    switch (change.action) {
        .Forwarded => {
            const source = typedRows(Member, change.rows);

            @memcpy(target[row..][0..source.len], source);
        },
        .Reexport => {
            var source = typedRows(Member, change.rows)[@intCast(change.source_row)];

            source.name = try allocator.dupe(u8, change.name);
            target[row] = source;
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
