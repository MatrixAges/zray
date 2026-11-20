const std = @import("std");
const zx = @import("zx");
const writing = @import("generated_uniqueness_trace_append");
const Input = std.meta.Child(writing.Input);
const Rows = std.meta.Child(@FieldType(Input, "owners"));
const RowBuffer = zx.memory.RowBuffer;

pub fn Log(comptime Value: type) type {
    return struct {
        owners: RowBuffer = .empty(u32),
        entries: RowBuffer = .empty(Entry),
        used: usize = 0,
        pub const Entry = struct { value: Value, state: []const u8 };

        pub fn ownersSlice(self: *const @This()) []const u32 {
            return self.owners.rows(u32)[0..self.used];
        }
        pub fn entriesSlice(self: *const @This()) []const Entry {
            return self.entries.rows(Entry)[0..self.used];
        }
        pub fn append(self: *@This(), allocator: std.mem.Allocator, owner: u32, value: Value, state: []const u8) std.mem.Allocator.Error!void {
            const entry: Entry = .{ .value = value, .state = state };

            const input: Input = .{
                .owners = &view(u32, &self.owners),
                .entries = &view(Entry, &self.entries),
                .owner = std.mem.asBytes(&owner),
                .entry = std.mem.asBytes(&entry),
                .used = self.used,
            };

            const used = zx.columns.invoke(writing.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
                error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
                else => unreachable,
            };

            self.used = @intCast(used);
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
