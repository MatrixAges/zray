const std = @import("std");
const zx = @import("zx");
const Trace = @import("../../trace.zig");
const Function = @import("../../function.zig");
const PlanWriter = @import("../../program/visit/plan_writer.zig");
const Replacement = @import("../shortcut.zig").Replacement;
const Reads = @import("../ordered/columns.zig").Planned;
const publishing = @import("generated_uniqueness_shortcut_publish");
const Input = std.meta.Child(publishing.Input);

pub fn apply(allocator: std.mem.Allocator, trace: *Trace, replay: *const Trace.Replay, replacements: []const Replacement, output: *PlanWriter) std.mem.Allocator.Error!void {
    const recorded = Reads.init(&.{"value"}, trace.planned.entries);
    const replacement = Reads.init(&.{"value"}, replacements);
    const View = std.meta.Child(@FieldType(Input, "recorded"));
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const input: Input = .{
        .planned = trace.planned.starts,
        .changed = replay.changed,
        .recorded = &recorded.view(View),
        .replacements = &replacement.view(View),
    };

    const result = zx.columns.invoke(publishing.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    for (result.functions) |update| output.rows[@intCast(update.body)] = try Function.Plan.fromColumns(update.value).copy(allocator);
    if (result.entry) |entry| output.entry = try Function.Plan.fromColumns(entry).copy(allocator);

    for (replacements) |replacement_row| {
        trace.planned.entries[replacement_row.visit].value = replacement_row.value;
    }

    @memcpy(trace.identities, replay.identities);
}
