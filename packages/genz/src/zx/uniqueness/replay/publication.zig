const std = @import("std");
const zx = @import("zx");
const Trace = @import("../trace.zig");
const build = @import("generated_uniqueness_trace_publication");
const Input = std.meta.Child(build.Input);
const Group = std.meta.Child(@FieldType(Input, "settled"));

pub fn capture(allocator: std.mem.Allocator, replay: *const Trace.Replay, trace: *Trace) std.mem.Allocator.Error!void {
    const first = try allocator.alloc(u64, replay.callees.len + 1);
    var edges: []u32 = &.{};
    const count = @typeInfo(Trace.Kind).@"enum".field_names.len;
    var targets: [count][]u8 = undefined;
    var groups: [count]Group = undefined;

    inline for (@typeInfo(Trace.Kind).@"enum".field_names, 0..) |kind, index| {
        const visits = &@field(trace, kind);
        const log = @field(replay, kind);
        const Row = std.meta.Child(@TypeOf(visits.entries));
        targets[index] = std.mem.sliceAsBytes(visits.entries);

        groups[index] = .{
            .count = replay.identities.len,
            .owners = log.owners.items,
            .first = @ptrCast(&visits.starts),
            .source = std.mem.sliceAsBytes(log.entries.items),
            .target = @ptrCast(&targets[index]),
            .width = @sizeOf(Row),
        };
    }

    const input: Input = .{
        .graph = &.{ .callees = replay.callees, .starts = @ptrCast(&first), .edges = @ptrCast(&edges) },
        .settled = &groups[0],
        .demanded = &groups[1],
        .planned = &groups[2],
    };

    zx.columns.invoke(build.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    trace.callees = .{ .starts = first, .edges = edges };
}
