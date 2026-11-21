const std = @import("std");
const zx = @import("zx");
const writing = @import("generated_uniqueness_trace_append");
const Input = std.meta.Child(writing.Input);
const Append = std.meta.Child(@FieldType(Input, "append"));
const Rows = std.meta.Child(@FieldType(Append, "owners"));
const Memo = @import("../memo.zig");
const target = @import("../row_output.zig").Target;
const views = @import("ordered/columns.zig");
const Comparison = target(Input, "comparison");
pub const Selection = target(Input, "selection");
const RowBuffer = zx.memory.RowBuffer;

pub fn Log(comptime Value: type) type {
    return struct {
        owners: RowBuffer = .empty(u32),
        entries: RowBuffer = .empty(Entry),
        used: usize = 0,
        pub const Entry = struct { value: Value, state: []const u8 };
        pub const History = struct { selection: Selection, entries: []const Entry };

        pub fn ownersSlice(self: *const @This()) []const u32 {
            return self.owners.rows(u32)[0..self.used];
        }
        pub fn entriesSlice(self: *const @This()) []const Entry {
            return self.entries.rows(Entry)[0..self.used];
        }
        pub fn append(self: *@This(), comptime kind: Memo.Kind, allocator: std.mem.Allocator, recording: std.mem.Allocator, owner: u32, value: Value, state: []const u8, history: ?*const History) std.mem.Allocator.Error!bool {
            const entry: Entry = .{ .value = value, .state = &.{} };
            var committed = [_]u64{self.used};
            const count: []u64 = &committed;
            const active = if (history) |previous| previous.selection.changed else false;
            var comparison: CompareRows(kind) = undefined;
            const before = if (active) &comparison.bind(history.?.entries, &value) else null;

            defer self.used = @intCast(committed[0]);

            const input: Input = .{
                .append = &.{
                    .owners = &view(u32, &self.owners),
                    .entries = &view(Entry, &self.entries),
                    .owner = std.mem.asBytes(&owner),
                    .entry = std.mem.asBytes(&entry),
                    .state_offset = @offsetOf(Entry, "state"),
                    .recording = @ptrCast(&recording),
                    .state = state,
                    .used = self.used,
                },
                .selection = if (history) |previous| &previous.selection else null,
                .comparison = &.{
                    .settled = if (kind == .settled) before else null,
                    .demanded = if (kind == .demanded) before else null,
                    .planned = if (kind == .planned) before else null,
                },
                .committed = @ptrCast(&count),
            };

            return zx.columns.invoke(writing.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
                error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
                else => unreachable,
            };
        }
    };
}

fn CompareRows(comptime kind: Memo.Kind) type {
    const Columns = switch (kind) {
        .settled => views.Settled,
        .demanded => views.Demanded,
        .planned => views.Planned,
    };

    const Pair = target(Comparison, @tagName(kind));
    const View = target(Pair, "left");
    const Binding = if (kind == .demanded) Columns.Binding(View) else void;

    return struct {
        columns: [2]Columns,
        binding: [2]Binding,
        descriptors: [2]View,
        fn bind(self: *@This(), previous: anytype, current: *const Memo.Result(kind)) Pair {
            const singleton: []const Memo.Result(kind) = @as(*const [1]Memo.Result(kind), @ptrCast(current));

            self.columns = .{ Columns.init(&.{"value"}, previous), Columns.init(&.{}, singleton) };

            for (&self.descriptors, &self.binding, &self.columns) |*descriptor, *state, *source| {
                descriptor.* = if (kind == .demanded) state.init(source) else source.view(View);
            }

            return .{ .left = &self.descriptors[0], .right = &self.descriptors[1] };
        }
    };
}

fn view(comptime Row: type, buffer: *const RowBuffer) Rows {
    return .{
        .rows = @ptrCast(buffer),
        .available = buffer.bytes.len / @sizeOf(Row),
        .granule = @max(1, std.atomic.cache_line / @sizeOf(Row)),
    };
}
