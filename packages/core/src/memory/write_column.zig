const std = @import("std");
const IndexError = error{IndexOutOfBounds};

pub const Column = struct {
    items: [*]u8,
    count: usize,
    stride: usize,
    width: usize,
};

pub const RowBuffer = struct {
    bytes: []u8 = &.{},
    stride: usize,
    alignment: std.mem.Alignment,
    fields: []const Field,
    columns: []Column,
    const Field = struct { offset: usize, width: usize };

    fn init(comptime Row: type, comptime fields: []const Field, columns: *[fields.len]Column) RowBuffer {
        return .{
            .stride = @sizeOf(Row),
            .alignment = .of(Row),
            .fields = fields,
            .columns = columns,
        };
    }

    pub fn rows(self: *const RowBuffer, comptime Row: type) []Row {
        std.debug.assert(self.stride == @sizeOf(Row) and self.alignment == std.mem.Alignment.of(Row));

        if (self.bytes.len == 0) return &.{};

        return std.mem.bytesAsSlice(Row, @as([]align(@alignOf(Row)) u8, @alignCast(self.bytes)));
    }
};

pub fn RowOutput(comptime Row: type, comptime View: type, comptime fields: anytype) type {
    const names = @typeInfo(View).@"struct".field_names;

    const layout = comptime block: {
        var result: [names.len]RowBuffer.Field = undefined;

        for (names, &result) |name, *field| {
            const location = @import("rows.zig").fieldLayout(Row, @field(fields, name));

            field.* = .{ .offset = location.offset, .width = @sizeOf(location.type) };
        }

        break :block result;
    };

    return struct {
        const Self = @This();

        buffer: RowBuffer,
        columns: [names.len]Column,
        view: View,
        pub fn init(self: *Self) void {
            self.buffer = RowBuffer.init(Row, &layout, &self.columns);

            inline for (names, 0..) |name, index| {
                self.columns[index] = .{ .items = undefined, .count = 0, .stride = @sizeOf(Row), .width = 0 };

                @field(self.view, name) = @ptrCast(&self.columns[index]);
            }
        }
        pub fn rows(self: *const Self) []Row {
            return self.buffer.rows(Row);
        }
    };
}

pub fn allocateRows(allocator: std.mem.Allocator, target: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const output: *RowBuffer = @ptrCast(@alignCast(@constCast(target)));
    const length = std.math.cast(usize, count) orelse return error.OutOfMemory;
    const size = std.math.mul(usize, length, output.stride) catch return error.OutOfMemory;

    std.debug.assert(output.bytes.len == 0);

    if (size == 0) return;

    const bytes = allocator.rawAlloc(size, output.alignment, @returnAddress()) orelse return error.OutOfMemory;

    output.bytes = bytes[0..size];

    for (output.fields, output.columns) |field, *column| {
        column.* = .{ .items = bytes + field.offset, .count = length, .stride = output.stride, .width = field.width };
    }
}

/// Publishes a newly allocated list in a slice field of its owning row.
pub fn allocateRowList(allocator: std.mem.Allocator, column: *const anyopaque, index: u64, target: *const anyopaque, count: u64) (std.mem.Allocator.Error || IndexError)!void {
    const output: *RowBuffer = @ptrCast(@alignCast(@constCast(target)));

    output.bytes = &.{};

    try allocateRows(allocator, target, count);
    try write([]const u8, column, index, output.bytes.ptr[0..@intCast(count)]);
}

pub fn copyRow(target: *const anyopaque, source: u64, destination: u64) IndexError!void {
    const output: *const RowBuffer = @ptrCast(@alignCast(target));
    const count = output.bytes.len / output.stride;

    if (source >= count or destination >= count or source == destination) return error.IndexOutOfBounds;

    const first = @as(usize, @intCast(source)) * output.stride;
    const next = @as(usize, @intCast(destination)) * output.stride;

    @memcpy(output.bytes[next..][0..output.stride], output.bytes[first..][0..output.stride]);
}

pub fn copyRowPrefix(target: *const anyopaque, source: []const u8, count: u64) IndexError!void {
    const output: *const RowBuffer = @ptrCast(@alignCast(target));
    const length = std.math.cast(usize, count) orelse return error.IndexOutOfBounds;
    const size = std.math.mul(usize, length, output.stride) catch return error.IndexOutOfBounds;

    if (size > output.bytes.len or size > source.len) return error.IndexOutOfBounds;

    @memcpy(output.bytes[0..size], source[0..size]);
}

/// The caller lends a mutable field of each row exclusively until the generated call returns.
pub inline fn borrow(comptime T: type, comptime field: []const u8, rows: anytype) Column {
    return borrowNested(T, &.{field}, rows);
}

pub inline fn borrowNested(comptime T: type, comptime fields: []const []const u8, rows: anytype) Column {
    const Row = std.meta.Child(@TypeOf(rows));
    const layout = comptime @import("rows.zig").fieldLayout(Row, fields);
    const Field = layout.type;

    comptime {
        if (@sizeOf(Field) != @sizeOf(T) or @alignOf(Field) != @alignOf(T)) {
            @compileError("Incompatible strided column field");
        }
    }

    const bytes: [*]u8 = @ptrCast(rows.ptr);

    return .{
        .items = if (rows.len == 0) bytes else bytes + layout.offset,
        .count = rows.len,
        .stride = @sizeOf(Row),
        .width = @sizeOf(T),
    };
}

pub inline fn writeU8(target: *const anyopaque, index: u64, value: u8) IndexError!void {
    return write(u8, target, index, value);
}

pub inline fn writeU32(target: *const anyopaque, index: u64, value: u32) IndexError!void {
    return write(u32, target, index, value);
}

pub inline fn writeU64(target: *const anyopaque, index: u64, value: u64) IndexError!void {
    return write(u64, target, index, value);
}

pub inline fn writeIndex(target: *const anyopaque, index: u64, value: u64) IndexError!void {
    return write(usize, target, index, std.math.cast(usize, value) orelse return error.IndexOutOfBounds);
}

pub inline fn writeBool(target: *const anyopaque, index: u64, value: bool) IndexError!void {
    return write(bool, target, index, value);
}

pub inline fn writeBytes(target: *const anyopaque, index: u64, value: []const u8) IndexError!void {
    return write([]const u8, target, index, value);
}

pub inline fn writeOptionalU32(target: *const anyopaque, index: u64, value: ?u32) IndexError!void {
    return write(?u32, target, index, value);
}

pub inline fn writeOptionalU8(target: *const anyopaque, index: u64, value: ?u8) IndexError!void {
    return write(?u8, target, index, value);
}

pub inline fn writeOptionalText(target: *const anyopaque, index: u64, value: ?[]const u8) IndexError!void {
    return write(?[]const u8, target, index, value);
}

pub inline fn writeTextList(target: *const anyopaque, index: u64, value: []const []const u8) IndexError!void {
    return write([]const []const u8, target, index, value);
}

/// Transfers a single cell's representation between compatible, disjoint borrowed fields.
pub inline fn copyValue(target: *const anyopaque, index: u64, value: []const u8) IndexError!void {
    const column: *const Column = @ptrCast(@alignCast(target));

    if (index >= column.count or value.len != column.width) return error.IndexOutOfBounds;

    const offset = @as(usize, @intCast(index)) * column.stride;

    @memcpy(column.items[offset..][0..column.width], value);
}

pub inline fn write(comptime T: type, target: *const anyopaque, index: u64, value: T) IndexError!void {
    const column: *const Column = @ptrCast(@alignCast(target));

    if (index >= column.count or column.width != @sizeOf(T)) return error.IndexOutOfBounds;

    const address = column.items + @as(usize, @intCast(index)) * column.stride;

    @as(*align(1) T, @ptrCast(address)).* = value;
}
