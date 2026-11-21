const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Trace = @import("../../trace.zig");
const Plan = @import("../../function.zig").Plan;
const Planned = @import("../../memo.zig").Planned;
const PlanWriter = @import("../../program/visit/plan_writer.zig");
const Replacement = @import("../shortcut.zig").Replacement;
const Reads = @import("../ordered/columns.zig").Planned;
const publishing = @import("generated_uniqueness_shortcut_publish");
const Input = std.meta.Child(publishing.Input);
const Plans = std.meta.Child(@FieldType(Input, "plans"));

pub fn apply(allocator: std.mem.Allocator, trace: *Trace, replay: *const Trace.Replay, replacements: []const Replacement, output: *PlanWriter) std.mem.Allocator.Error!void {
    const recorded = Reads.init(&.{"value"}, trace.planned.entries);
    const replacement = Reads.init(&.{"value"}, replacements);
    const View = std.meta.Child(@FieldType(Plans, "recorded"));
    const functions = Writes.init(output.rows);
    const entry = Writes.init(@as(*[1]Plan, @ptrCast(&output.entry)));
    const positions = memory.borrowReadColumn(u32, "visit", replacements);
    const values = memory.borrowReadColumn(Planned, "value", replacements);
    const records = memory.borrowWriteColumn(Planned, "value", trace.planned.entries);
    const identities = std.mem.sliceAsBytes(trace.identities);

    const input: Input = .{
        .plans = &.{
            .planned = trace.planned.starts,
            .changed = replay.changed,
            .recorded = &recorded.view(View),
            .replacements = &replacement.view(View),
            .functions = &functions.view(),
            .entry = &entry.view(),
        },
        .commit = &.{
            .count = replacements.len,
            .width = @sizeOf(Planned),
            .positions = @ptrCast(&positions),
            .values = @ptrCast(&values),
            .records = @ptrCast(&records),
            .old_identities = @ptrCast(&identities),
            .identities = std.mem.sliceAsBytes(replay.identities),
        },
    };

    zx.columns.invoke(publishing.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

const Writes = struct {
    flags: memory.WriteColumn,
    keys: memory.WriteColumn,
    paths: memory.WriteColumn,
    transfers: memory.WriteColumn,
    slot_first: memory.WriteColumn,
    const View = std.meta.Child(@FieldType(Plans, "functions"));

    fn init(rows: []Plan) Writes {
        return .{
            .flags = memory.borrowWriteColumn([]const u8, "flags", rows),
            .keys = memory.borrowNestedWriteColumn([]const u64, &.{ "renewals", "keys" }, rows),
            .paths = memory.borrowNestedWriteColumn([]const []const u32, &.{ "renewals", "paths" }, rows),
            .transfers = memory.borrowWriteColumn([]const u64, "transfers", rows),
            .slot_first = memory.borrowWriteColumn([]const u32, "slot_first", rows),
        };
    }
    fn view(self: *const Writes) View {
        var result: View = undefined;

        inline for (@typeInfo(View).@"struct".field_names) |name| @field(result, name) = @ptrCast(&@field(self, name));

        return result;
    }
};
