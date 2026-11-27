const std = @import("std");
const zx = @import("zx");
const Trace = @import("../trace.zig");
const build = @import("generated_uniqueness_trace_publication");
const Input = std.meta.Child(build.Input);
const Group = std.meta.Child(@FieldType(Input, "settled"));

pub fn capture(allocator: std.mem.Allocator, replay: *const Trace.Replay, trace: *Trace) std.mem.Allocator.Error!void {
    const kinds = @typeInfo(Trace.Kind).@"enum".field_names;
    const count = kinds.len;
    var groups: [count]Group = undefined;

    inline for (kinds, 0..) |kind, index| {
        groups[index] = .{
            .count = replay.identities.len,
            .owners = @field(replay, kind).ownersSlice(),
        };
    }

    const input: Input = .{
        .identities = &.{
            .source = std.mem.sliceAsBytes(replay.identities),
            .count = replay.identities.len,
            .width = @sizeOf(Trace.Digest),
        },
        .graph = &.{ .callees = replay.callees },
        .settled = &groups[0],
        .demanded = &groups[1],
        .planned = &groups[2],
    };

    const built = zx.columns.invoke(build.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    trace.identities = std.mem.bytesAsSlice(Trace.Digest, try allocator.dupe(u8, built.identities));
    trace.callees = .{ .starts = built.graph.starts, .edges = built.graph.edges };

    inline for (kinds) |kind| {
        const log = &@field(replay, kind);
        const Row = @TypeOf(log.*).Entry;
        const src_entries = log.entriesSlice();
        const group = @field(built, kind);
        const entries = try allocator.alloc(Row, group.order.len);

        for (group.order, 0..) |src_idx, dst_idx| entries[dst_idx] = src_entries[src_idx];

        @field(trace, kind) = .{ .starts = try allocator.dupe(u32, group.starts), .entries = entries };
    }
}
