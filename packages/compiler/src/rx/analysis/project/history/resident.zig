const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const columns = zx.columns;
const Digest = @import("../history.zig").Digest;
const Source = @import("frontend").project.Source;
const generated = @import("rx_options").generated_graph;
const Error = std.mem.Allocator.Error;
pub const Selection = struct { parent_count: usize = 0, rx_only: bool = false, same_input: bool = false };
pub const Publication = struct { restore: bool, parent_count: usize, capture_edits: bool, release_history: bool };

pub fn select(epochs: anytype, frame: *const [32]u8, shape: *const [32]u8, digests: []const Digest, sources: []const Source) Selection {
    if (epochs.len == 0) return .{};
    if (comptime !generated) return @import("resident/seed.zig").select(Selection, epochs, frame, shape, digests, sources);

    const rule = @import("generated_rx_history_parent");
    const Input = std.meta.Child(rule.Input);
    const latest = &epochs[epochs.len - 1];
    const earlier = latest.snapshot.sources;
    const earlier_paths = memory.borrowTextColumn("path", earlier);
    const earlier_texts = memory.borrowTextColumn("source", earlier);
    const current_paths = memory.borrowTextColumn("path", sources);
    const current_texts = memory.borrowTextColumn("source", sources);
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
            .earlier = &.{ .paths = @ptrCast(&earlier_paths), .texts = @ptrCast(&earlier_texts) },
            .current = &.{ .paths = @ptrCast(&current_paths), .texts = @ptrCast(&current_texts) },
            .first = 0,
            .end = sources.len,
        },
        .epochs = &.{ .frames = @ptrCast(&frames), .edits = @ptrCast(&edits), .count = epochs.len },
        .digests = &.{ .earlier = @ptrCast(&earlier_digests), .current = @ptrCast(&current_digests), .width = @sizeOf(@FieldType(Digest, "digest")) },
        .frame = frame,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const found = columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return .{ .parent_count = @intCast(found.parent_count), .rx_only = found.rx_only, .same_input = found.same_input };
}

pub fn changes(allocator: std.mem.Allocator, previous: []const Digest, current: []const Digest) Error![]const u64 {
    if (comptime !generated) return @import("resident/seed.zig").changes(allocator, previous, current);

    const rule = @import("generated_rx_history_changes");
    const earlier = memory.borrowReadColumn(@FieldType(Digest, "digest"), "digest", previous);
    const after = memory.borrowReadColumn(@FieldType(Digest, "digest"), "digest", current);
    const input: std.meta.Child(rule.Input) = .{ .earlier = @ptrCast(&earlier), .current = @ptrCast(&after), .width = @sizeOf(@FieldType(Digest, "digest")) };

    return columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

pub fn publication(selected: Selection, borrowed: bool) Publication {
    if (comptime !generated) return .{
        .restore = selected.same_input,
        .parent_count = if (selected.same_input or borrowed) selected.parent_count else 0,
        .capture_edits = !selected.same_input and borrowed and selected.rx_only,
        .release_history = !selected.same_input and !borrowed,
    };

    const rule = @import("generated_rx_history_publication");
    const input: std.meta.Child(rule.Input) = .{ .parent_count = selected.parent_count, .rx_only = selected.rx_only, .same_input = selected.same_input, .borrows_previous = borrowed };
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const plan = columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

    return .{ .restore = plan.restore, .parent_count = @intCast(plan.parent_count), .capture_edits = plan.capture_edits, .release_history = plan.release_history };
}
