const std = @import("std");
const zx = @import("zx");
const rows = @import("../row_output.zig");
const Memo = @import("../memo.zig");
const disk = @import("disk.zig");
const Error = std.mem.Allocator.Error;

pub fn load(memo: *Memo, source: []const u8) Error!void {
    const owner = memo.arena.child_allocator;
    const layout = (try disk.inspect(owner, source)) orelse return;
    const loader: Loader = .{ .owner = owner, .payload = memo.arena.allocator(), .source = source };

    try loader.settled(&memo.settled, .{ .start = layout.settled_start, .count = layout.settled_count });
    try loader.demanded(&memo.demanded, .{ .start = layout.demanded_start, .count = layout.demanded_count });

    try loader.section(@import("generated_uniqueness_memo_load_plan"), &memo.planned, .{
        .start = layout.planned_start,
        .count = layout.planned_count,
    }, .{
        .flags = &.{"flags"},
        .keys = &.{ "renewals", "keys" },
        .paths = &.{ "renewals", "paths" },
        .transfers = &.{"transfers"},
        .slot_first = &.{"slot_first"},
        .used = &.{"used"},
    }, .{});

    try loader.section(@import("generated_uniqueness_memo_load_flow"), &memo.flowed, .{
        .start = layout.flowed_start,
        .count = layout.flowed_count,
    }, .{
        .held = &.{"held"},
        .text_held = &.{"text_held"},
        .written = &.{"written"},
        .used = &.{"used"},
    }, .{});
}

const Span = struct { start: u64, count: u32 };

const Loader = struct {
    owner: std.mem.Allocator,
    payload: std.mem.Allocator,
    source: []const u8,
    fn settled(self: Loader, table: anytype, bounds: Span) Error!void {
        const entry = @import("generated_uniqueness_memo_load_settlement");
        const Input = std.meta.Child(entry.Input);
        var passed: rows.Contributions(Input, "passed") = undefined;

        passed.init();

        try self.section(entry, table, bounds, .{
            .passed = &.{"passed"},
            .output = &.{"output"},
            .used = &.{"used"},
        }, .{ .passed = &passed });
    }
    fn demanded(self: Loader, table: anytype, bounds: Span) Error!void {
        const entry = @import("generated_uniqueness_memo_load_demand");
        const Input = std.meta.Child(entry.Input);
        var marks: rows.Marks(Input, "marks") = undefined;
        var normalized: rows.Normalized(Input) = undefined;
        var renewed: rows.Renewed(Input) = undefined;

        marks.init();
        normalized.init();
        renewed.init();

        try self.section(entry, table, bounds, .{
            .marks = &.{"marks"},
            .normalized = &.{"normalized"},
            .renewed = &.{"renewed"},
            .grew = &.{"grew"},
            .used = &.{"used"},
        }, .{ .marks = &marks, .normalized = &normalized, .renewed = &renewed });
    }
    fn section(self: Loader, comptime entry: type, table: anytype, bounds: Span, comptime fields: anytype, buffers: anytype) Error!void {
        if (bounds.count == 0) return;
        try table.ensureUnusedCapacity(self.owner, bounds.count);

        const Input = std.meta.Child(entry.Input);
        const Columns = std.meta.Child(@FieldType(Input, "target"));
        const Value = std.meta.Elem(@TypeOf(table.values.items));
        var target: zx.memory.RowOutput(Value, Columns, fields) = undefined;
        var frame: @TypeOf(table.*).Publication(std.meta.Child(@FieldType(Input, "index"))) = undefined;

        target.init();
        target.bind(table.values.allocatedSlice());
        frame.open(table);

        var input: Input = undefined;

        input.source = self.source;
        input.start = bounds.start;
        input.count = bounds.count;
        input.target = &target.view;
        input.index = &frame.index;
        input.used = @intCast(table.keys.items.len);

        inline for (@typeInfo(@TypeOf(buffers)).@"struct".field_names) |name| {
            const buffer = @field(buffers, name);

            @field(input, name) = &.{ .storage = @ptrCast(&buffer.buffer), .columns = &buffer.view };
        }

        const borrowed: *const Input = &input;

        const outcome = zx.columns.invoke(entry.executeValue, self.payload, borrowed) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.debug.panic("validated memo section could not be decoded: {s}", .{@errorName(err)}),
        };

        frame.finish(table, outcome.used);

        if (!outcome.valid) @panic("validated memo section ended early");
    }
};
