const std = @import("std");
const zx = @import("zx");
const writing = @import("generated_uniqueness_trace_append");
const Input = std.meta.Child(writing.Input);
const Memo = @import("../memo.zig");
const target = @import("../row_output.zig").Target;
const views = @import("ordered/columns.zig");
const Comparison = target(Input, "comparison");
pub const Selection = @import("root.zig").Visit;

pub fn Log(comptime Value: type) type {
    return struct {
        owners: std.ArrayList(u32) = .empty,
        entries: std.ArrayList(Entry) = .empty,
        used: usize = 0,
        pub const Entry = struct { value: Value, state: []const u8 };
        pub const History = struct { selection: Selection, entries: []const Entry };

        pub fn ownersSlice(self: *const @This()) []const u32 {
            return self.owners.items;
        }
        pub fn entriesSlice(self: *const @This()) []const Entry {
            return self.entries.items;
        }
        pub fn append(self: *@This(), comptime kind: Memo.Kind, allocator: std.mem.Allocator, recording: std.mem.Allocator, owner: u32, value: Value, state: []const u8, history: ?*const History) std.mem.Allocator.Error!bool {
            const active = if (history) |previous| previous.selection.changed else false;
            var comparison: CompareRows(kind) = undefined;
            const before = if (active) &comparison.bind(history.?.entries, &value) else null;
            const Visit = target(Input, "selection");
            const selection = if (history) |previous| previous.selection.input(Visit) else undefined;

            const input: Input = .{
                .selection = if (history != null) &selection else null,
                .comparison = &.{
                    .settled = if (kind == .settled) before else null,
                    .demanded = if (kind == .demanded) before else null,
                    .planned = if (kind == .planned) before else null,
                },
            };

            const result = zx.columns.invoke(writing.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
                error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
                else => unreachable,
            };

            try self.owners.ensureUnusedCapacity(allocator, 1);
            try self.entries.ensureUnusedCapacity(allocator, 1);

            const retained = try recording.dupe(u8, state);

            errdefer recording.free(retained);

            if (history) |previous| try previous.selection.advance(allocator, result.next);

            self.owners.appendAssumeCapacity(owner);
            self.entries.appendAssumeCapacity(.{ .value = value, .state = retained });

            self.used = self.entries.items.len;

            return result.following;
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
