const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const Memo = @import("../memo.zig");
const Level = @import("../level.zig").Level;
const rule = @import("generated_uniqueness_memo_write");
const Input = Value(rule.Input);
const Error = std.mem.Allocator.Error;

pub fn save(memo: *const Memo, allocator: std.mem.Allocator) Error![]u8 {
    var settled: View(@FieldType(Input, "settled")) = undefined;
    var demanded: View(@FieldType(Input, "demanded")) = undefined;
    var planned: View(@FieldType(Input, "planned")) = undefined;
    var flowed: View(@FieldType(Input, "flowed")) = undefined;
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const settlements = memo.settled.values.items;
    const demands = memo.demanded.values.items;
    const plans = memo.planned.values.items;
    const flows = memo.flowed.values.items;

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
        .settled = settled.borrow(memo.settled.keys.items, settlements, &settlement_fields),
        .demanded = demanded.borrow(memo.demanded.keys.items, demands, &demand_fields),
        .planned = planned.borrow(memo.planned.keys.items, plans, &plan_fields),
        .flowed = flowed.borrow(memo.flowed.keys.items, flows, &flow_fields),
    };

    const encoded = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("memo disk write failed: {s}", .{@errorName(err)}),
    };

    return allocator.dupe(u8, encoded);
}

fn View(comptime Target: type) type {
    const Table = Value(Target);
    const Rows = Value(@FieldType(Table, "rows"));

    return struct {
        used: memory.ReadColumn,
        rows: Rows,
        table: Table,
        fn borrow(self: *@This(), keys: []const Memo.Digest, rows: anytype, fields: anytype) Target {
            self.used = memory.borrowReadColumn(bool, "used", rows);

            self.rows = .{
                .keys = std.mem.sliceAsBytes(keys),
                .used = @ptrCast(&self.used),
            };

            inline for (@typeInfo(Table).@"struct".field_names) |name| {
                @field(self.table, name) = if (comptime std.mem.eql(u8, name, "rows"))
                    if (@typeInfo(@FieldType(Table, name)) == .pointer) &self.rows else self.rows

                else if (comptime std.mem.eql(u8, name, "zx_origin"))
                    null
                else
                    @ptrCast(&@field(fields.*, name));
            }

            return if (@typeInfo(Target) == .pointer) &self.table else self.table;
        }
    };
}

fn Value(comptime T: type) type {
    return if (@typeInfo(T) == .pointer) std.meta.Child(T) else T;
}
