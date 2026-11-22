const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const columns = zx.columns;
const Digest = @import("../history.zig").Digest;
const Source = @import("frontend").project.Source;
const SourceColumns = @import("admission.zig").SourceColumns;
const generated = @import("rx_options").generated_graph;
const Error = std.mem.Allocator.Error;
pub const Selection = struct { parent_count: usize = 0, rx_only: bool = false, same_input: bool = false };

pub const Publication = struct {
    restore: bool,
    parent_count: usize,
    release_history: bool,
    slots: usize,
    edits: ?[]const u64,
};

/// Returns the length of the prefix ending in the latest exact match.
pub fn exact(epochs: anytype, fingerprint: *const [32]u8) usize {
    if (epochs.len == 0) return 0;

    if (comptime !generated) {
        var count = epochs.len;

        while (count != 0 and !zx.bytes.equal(&epochs[count - 1].fingerprint, fingerprint)) count -= 1;

        return count;
    }

    const rule = @import("generated_rx_history_exact");
    const fingerprints = memory.borrowReadColumn([32]u8, "fingerprint", epochs);

    const input: std.meta.Child(rule.Input) = .{
        .count = epochs.len,
        .fingerprints = @ptrCast(&fingerprints),
        .current = fingerprint,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return @intCast(columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable);
}

pub fn select(epochs: anytype, frame: *const [32]u8, shape: *const [32]u8, digests: []const Digest, sources: []const Source) Selection {
    if (epochs.len == 0) return .{};
    if (comptime !generated) return @import("resident/seed.zig").select(Selection, epochs, frame, shape, digests, sources);

    const rule = @import("generated_rx_history_parent");
    const Input = std.meta.Child(rule.Input);
    const Pair = std.meta.Child(@FieldType(Input, "sources"));
    const View = std.meta.Child(@FieldType(Pair, "earlier"));
    const latest = &epochs[epochs.len - 1];
    const earlier = latest.snapshot.sources;
    const before = SourceColumns.init(earlier);
    const after = SourceColumns.init(sources);
    const old_rx_paths = memory.borrowTextColumn("path", latest.rx_digests);
    const new_rx_paths = memory.borrowTextColumn("path", digests);
    const earlier_digests = memory.borrowReadColumn(@FieldType(Digest, "digest"), "digest", latest.rx_digests);
    const current_digests = memory.borrowReadColumn(@FieldType(Digest, "digest"), "digest", digests);
    const frames = memory.borrowNestedColumn([32]u8, &.{ "snapshot", "frame" }, epochs);
    const edits = memory.borrowReadColumn(?[]const u64, "edited_rx", epochs);

    const input: Input = .{
        .shape = &.{ .earlier = &latest.snapshot.shape, .current = shape, .earlier_count = earlier.len, .current_count = sources.len },
        .paths = &.{ .earlier = @ptrCast(&old_rx_paths), .current = @ptrCast(&new_rx_paths), .earlier_count = latest.rx_digests.len, .current_count = digests.len },
        .sources = &.{
            .earlier = &before.view(View),
            .current = &after.view(View),
            .earlier_count = before.count,
            .current_count = after.count,
        },
        .epochs = &.{ .frames = @ptrCast(&frames), .edits = @ptrCast(&edits), .count = epochs.len },
        .digests = &.{ .earlier = @ptrCast(&earlier_digests), .current = @ptrCast(&current_digests), .width = @sizeOf(@FieldType(Digest, "digest")) },
        .frame = frame,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const found = columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return .{ .parent_count = @intCast(found.parent_count), .rx_only = found.rx_only, .same_input = found.same_input };
}

pub fn publication(allocator: std.mem.Allocator, selected: Selection, borrowed: bool, previous: []const Digest, current: []const Digest) Error!Publication {
    if (comptime !generated) {
        const parents = if (selected.same_input or borrowed) selected.parent_count else 0;
        const capture = !selected.same_input and borrowed and selected.rx_only;

        return .{
            .restore = selected.same_input,
            .parent_count = parents,
            .release_history = !selected.same_input and !borrowed,
            .slots = parents + @as(usize, @intFromBool(!selected.same_input)),
            .edits = if (capture) try @import("resident/seed.zig").changes(allocator, previous, current) else null,
        };
    }

    const rule = @import("generated_rx_history_commit");
    const earlier = memory.borrowReadColumn(@FieldType(Digest, "digest"), "digest", previous);
    const after = memory.borrowReadColumn(@FieldType(Digest, "digest"), "digest", current);

    const input: std.meta.Child(rule.Input) = .{
        .selection = &.{ .parent_count = selected.parent_count, .rx_only = selected.rx_only, .same_input = selected.same_input, .borrows_previous = borrowed },
        .digests = &.{ .earlier = @ptrCast(&earlier), .current = @ptrCast(&after), .width = @sizeOf(@FieldType(Digest, "digest")) },
    };

    const plan = columns.invoke(rule.executeValue, allocator, &input) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .restore = plan.action.restore,
        .parent_count = @intCast(plan.action.parent_count),
        .release_history = plan.action.release_history,
        .slots = @intCast(plan.action.slots),
        .edits = plan.edits,
    };
}

pub fn capacity(parent: u64, analysis: usize, inputs: usize) u64 {
    if (comptime !generated) return parent + analysis + inputs;

    const rule = @import("generated_rx_history_capacity");
    const Input = if (@typeInfo(rule.Input) == .pointer) std.meta.Child(rule.Input) else rule.Input;
    const input: Input = .{ .parent = parent, .analysis = analysis, .inputs = inputs };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}
