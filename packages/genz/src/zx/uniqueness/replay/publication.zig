const std = @import("std");
const zx = @import("zx");
const Trace = @import("../trace.zig");
const build = @import("generated_uniqueness_trace_publication");
const Input = std.meta.Child(build.Input);
const Group = std.meta.Child(@FieldType(Input, "settled"));

pub fn capture(allocator: std.mem.Allocator, replay: *const Trace.Replay, trace: *Trace) std.mem.Allocator.Error!void {
    const kinds = @typeInfo(Trace.Kind).@"enum".field_names;
    const count = kinds.len;
    const RowBuffer = zx.memory.RowBuffer;
    var identities: RowBuffer = .empty(Trace.Digest);
    var first: []u64 = &.{};
    var edges: []u32 = &.{};
    var starts: [count][]u32 = @splat(&.{});
    var targets: [count]RowBuffer = undefined;
    var groups: [count]Group = undefined;

    inline for (kinds, 0..) |kind, index| {
        const log = &@field(replay, kind);
        const Row = @TypeOf(log.*).Entry;

        targets[index] = .empty(Row);

        groups[index] = .{
            .count = replay.identities.len,
            .owners = log.ownersSlice(),
            .first = @ptrCast(&starts[index]),
            .source = std.mem.sliceAsBytes(log.entriesSlice()),
            .target = @ptrCast(&targets[index]),
            .width = @sizeOf(Row),
        };
    }

    const input: Input = .{
        .identities = &.{
            .source = std.mem.sliceAsBytes(replay.identities),
            .target = @ptrCast(&identities),
            .count = replay.identities.len,
        },
        .graph = &.{ .callees = replay.callees, .starts = @ptrCast(&first), .edges = @ptrCast(&edges) },
        .settled = &groups[0],
        .demanded = &groups[1],
        .planned = &groups[2],
    };

    zx.columns.invoke(build.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    trace.identities = identities.rows(Trace.Digest);
    trace.callees = .{ .starts = first, .edges = edges };

    inline for (kinds, 0..) |kind, index| {
        const Row = @TypeOf(@field(replay, kind)).Entry;

        @field(trace, kind) = .{ .starts = starts[index], .entries = targets[index].rows(Row) };
    }
}
