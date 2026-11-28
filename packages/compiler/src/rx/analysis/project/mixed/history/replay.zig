const std = @import("std");
const History = @import("../../history.zig");
const State = @import("../state.zig");
const Borrowed = @import("admit.zig").Borrowed;
const columns = @import("../../history/columns.zig");
const rule = @import("generated_rx_mixed_history_replay");
const Input = std.meta.Child(rule.Input);

pub fn run(state: *State, previous: *const History.Retained, prefix: *const Borrowed, boundaries: []History.Checkpoint, first: usize, end: usize, reused: *usize) std.mem.Allocator.Error!usize {
    const graph = &state.graph;
    const order = columns.words(std.mem.sliceAsBytes(graph.order));

    const input: Input = .{
        .window = &.{
            .order = @ptrCast(&order),
            .first = first,
            .end = end,
            .entry = graph.entry,
            .sources = &.{ .zx_count = graph.sources.zx_count, .rx_end = graph.sources.rx_end },
            .history = &prefix.history,
        },
        .column_count = prefix.transfers.len,
        .publication = &.{
            .rows = @ptrCast(&order),
            .modules = &.{
                .surfaces = @sizeOf(std.meta.Elem(@TypeOf(state.finished.surfaces))),
                .functions = @sizeOf(std.meta.Elem(@TypeOf(state.finished.functions))),
                .present = @sizeOf(bool),
                .available = previous.finished.present,
            },
            .checkpoints = @sizeOf(History.Checkpoint),
            .reused_before = reused.*,
        },
    };

    var scratch = std.heap.ArenaAllocator.init(state.scratch.child_allocator);

    defer scratch.deinit();

    const result = rule.executeIn(scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (result.publication) |publication| {
        for (result.ranges) |range| {
            _ = try prefix.transfers[@intCast(range.column)].reserve(state.allocator, @intCast(range.count));
        }

        for (result.ranges) |range| {
            prefix.transfers[@intCast(range.column)].appendBorrowed(@intCast(range.first), @intCast(range.count));
        }

        for (publication.modules) |module| {
            copySpan(state.finished.present, previous.finished.present, module.present);

            if (module.surfaces) |span| copySpan(state.finished.surfaces, previous.finished.surfaces, span);
            if (module.functions) |span| copySpan(state.finished.functions, previous.finished.functions, span);
        }

        copySpan(boundaries, previous.boundaries, publication.checkpoints);

        state.verified = @intCast(publication.counters.verified);
        reused.* = @intCast(publication.counters.reused);
    }

    return @intCast(result.position);
}

fn copySpan(current: anytype, earlier: anytype, span: anytype) void {
    const first: usize = @intCast(span.first);
    const end: usize = @intCast(span.end);

    @memmove(std.mem.sliceAsBytes(current)[first..end], std.mem.sliceAsBytes(earlier)[first..end]);
}
