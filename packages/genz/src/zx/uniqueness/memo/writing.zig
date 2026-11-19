const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Memo = @import("../memo.zig");
const Level = @import("../level.zig").Level;
const rule = @import("generated_uniqueness_memo_write");
const Input = Value(rule.Input);
const Error = std.mem.Allocator.Error;

pub fn save(memo: *const Memo, allocator: std.mem.Allocator) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);

    errdefer out.deinit();

    var settled: View(@FieldType(Input, "settled")) = undefined;
    var demanded: View(@FieldType(Input, "demanded")) = undefined;
    var planned: View(@FieldType(Input, "planned")) = undefined;
    var flowed: View(@FieldType(Input, "flowed")) = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const settlements = mapRows(&memo.settled);
    const demands = mapRows(&memo.demanded);
    const plans = mapRows(&memo.planned);
    const flows = mapRows(&memo.flowed);

    const settlement_fields = .{
        .callees = memory.borrowListColumn(u32, "passed", "callee", settlements),
        .levels = memory.borrowListColumn([]const Level, "passed", "levels", settlements),
        .output = memory.borrowSliceColumn(&.{"output"}, settlements),
    };

    const demand_fields = .{
        .marks_output = memory.borrowListColumn(bool, "marks", "output", demands),
        .marks_function = memory.borrowListColumn(u32, "marks", "function", demands),
        .marks_slot = memory.borrowListColumn(u32, "marks", "slot", demands),
        .marks_want = memory.borrowListColumn(Level, "marks", "want", demands),
        .normalized_id = memory.borrowListColumn(zx.ir.ExprId, "normalized", "id", demands),
        .normalized_want = memory.borrowListColumn(Level, "normalized", "want", demands),
        .renewed_key = memory.borrowListColumn(u64, "renewed", "key", demands),
        .renewed_want = memory.borrowListColumn(Level, "renewed", "want", demands),
        .grew = memory.borrowReadColumn(bool, "grew", demands),
    };

    const plan_fields = .{
        .flags = memory.borrowSliceColumn(&.{"flags"}, plans),
        .keys = memory.borrowNestedColumn([]const u64, &.{ "renewals", "keys" }, plans),
        .paths = memory.borrowNestedColumn([]const []const u32, &.{ "renewals", "paths" }, plans),
        .transfers = memory.borrowReadColumn([]const u64, "transfers", plans),
        .slot_first = memory.borrowReadColumn([]const u32, "slot_first", plans),
    };

    const flow_fields = .{
        .held = memory.borrowSliceColumn(&.{"held"}, flows),
        .text_held = memory.borrowSliceColumn(&.{"text_held"}, flows),
        .written = memory.borrowSliceColumn(&.{"written"}, flows),
    };

    const input: Input = .{
        .writer = @ptrCast(&out.writer),
        .settled = settled.borrow(memo.settled.keyIterator(), settlements, &settlement_fields),
        .demanded = demanded.borrow(memo.demanded.keyIterator(), demands, &demand_fields),
        .planned = planned.borrow(memo.planned.keyIterator(), plans, &plan_fields),
        .flowed = flowed.borrow(memo.flowed.keyIterator(), flows, &flow_fields),
    };

    zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("memo disk write failed: {s}", .{@errorName(err)}),
    };

    return out.toOwnedSlice();
}

fn mapRows(map: anytype) []const @TypeOf(map.valueIterator().items[0]) {
    const rows = map.valueIterator();

    return if (rows.len == 0) &.{} else rows.items[0..rows.len];
}

fn View(comptime Target: type) type {
    const Table = Value(Target);
    const Slots = Value(@FieldType(Table, "slots"));

    return struct {
        used: memory.ReadColumn,
        slots: Slots,
        table: Table,
        fn borrow(self: *@This(), keys: anytype, rows: anytype, fields: anytype) Target {
            const Metadata = @TypeOf(keys.metadata[0]);
            const occupied = comptime occupiedFloor(Metadata);

            self.used = memory.borrowReadColumn(bool, "used", rows);

            self.slots = .{
                .metadata = if (keys.len == 0) &.{} else std.mem.sliceAsBytes(keys.metadata[0..keys.len]),
                .occupied = occupied,
                .keys = if (keys.len == 0) &.{} else std.mem.sliceAsBytes(keys.items[0..keys.len]),
                .used = @ptrCast(&self.used),
            };

            inline for (@typeInfo(Table).@"struct".field_names) |name| {
                @field(self.table, name) = if (comptime std.mem.eql(u8, name, "slots"))
                    if (@typeInfo(@FieldType(Table, name)) == .pointer) &self.slots else self.slots

                else if (comptime std.mem.eql(u8, name, "zx_origin"))
                    null
                else
                    @ptrCast(&@field(fields.*, name));
            }

            return if (@typeInfo(Target) == .pointer) &self.table else self.table;
        }
    };
}

/// The standard table's forward iterators expose the same bucket order for keys and values.
fn occupiedFloor(comptime Metadata: type) u8 {
    comptime {
        std.debug.assert(@bitSizeOf(Metadata) == @bitSizeOf(u8));
        std.debug.assert(@bitOffsetOf(Metadata, "used") == @bitSizeOf(u7));
    }

    return @bitCast(Metadata{ .used = 1 });
}

fn Value(comptime T: type) type {
    return if (@typeInfo(T) == .pointer) std.meta.Child(T) else T;
}
