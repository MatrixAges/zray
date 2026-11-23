const std = @import("std");
const ReadColumn = @import("rows.zig").ReadColumn;
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

    pub fn empty(comptime Row: type) RowBuffer {
        return .{
            .stride = @sizeOf(Row),
            .alignment = .of(Row),
            .fields = &.{},
            .columns = &.{},
        };
    }

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
    inline fn refreshCell(self: *RowBuffer, slot: usize, count: usize) void {
        const field = self.fields[slot];

        self.columns[slot] = .{
            .items = if (count == 0) self.bytes.ptr else self.bytes.ptr + field.offset,
            .count = count,
            .stride = self.stride,
            .width = field.width,
        };
    }
};

pub fn RowOutput(comptime Row: type, comptime View: type, comptime fields: anytype) type {
    const names = @typeInfo(View).@"struct".field_names;

    const layout = comptime block: {
        var result: [names.len]RowBuffer.Field = undefined;

        for (names, &result) |name, *field| {
            const path: []const []const u8 = if (@hasField(@TypeOf(fields), name)) @field(fields, name) else &.{name};
            const location = @import("rows.zig").fieldLayout(Row, path);

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

        pub fn bind(self: *Self, storage: []Row) void {
            self.buffer.bytes = std.mem.sliceAsBytes(storage);

            inline for (0..names.len) |slot| self.buffer.refreshCell(slot, storage.len);
        }
    };
}

pub const RowGrowth = struct {
    target: *RowBuffer,
    reads: []ReadColumn,
    pub inline fn refreshCell(self: RowGrowth, slot: usize, count: usize) void {
        const buffer = self.target;
        const field = buffer.fields[slot];
        self.reads[slot] = .{ .bytes = buffer.bytes, .count = count, .stride = buffer.stride, .offset = field.offset };
    }
};

inline fn rowBuffer(target: *const anyopaque) *RowBuffer {
    return @ptrCast(@alignCast(@constCast(target)));
}

inline fn rowGrowth(target: *const anyopaque) *const RowGrowth {
    return @ptrCast(@alignCast(target));
}

pub inline fn rowFieldCount(target: *const anyopaque) u64 {
    return rowBuffer(target).fields.len;
}

pub inline fn rowStorageCount(target: *const anyopaque) u64 {
    const buffer = rowBuffer(target);

    return buffer.bytes.len / buffer.stride;
}

pub inline fn rowCapacityLimit() u64 {
    return std.math.maxInt(usize);
}

pub inline fn rowGrowthBase(target: *const anyopaque, used: u64) u64 {
    std.debug.assert(used == rowStorageCount(target));

    return @max(1, std.atomic.cache_line / rowBuffer(target).stride);
}

pub inline fn rowGrowthBuffer(target: *const anyopaque, output: anytype) std.meta.Child(@TypeOf(output)) {
    return @ptrCast(rowGrowth(target).target);
}

pub inline fn refreshRowWrite(target: *const anyopaque, slot: u64, count: u64) void {
    rowBuffer(target).refreshCell(@intCast(slot), @intCast(count));
}

pub inline fn refreshRowRead(target: *const anyopaque, slot: u64, count: u64) void {
    rowGrowth(target).refreshCell(@intCast(slot), @intCast(count));
}

pub inline fn clearRowStorage(target: *const anyopaque) void {
    rowBuffer(target).bytes = &.{};
}

pub fn reserveRowStorage(allocator: std.mem.Allocator, target: *const anyopaque, used: u64, count: u64) std.mem.Allocator.Error!bool {
    const buffer = rowBuffer(target);
    const length = std.math.cast(usize, used) orelse return error.OutOfMemory;
    const capacity = std.math.cast(usize, count) orelse return error.OutOfMemory;
    const previous = buffer.bytes;
    const stride = buffer.stride;

    std.debug.assert(length <= previous.len / stride);

    if (capacity <= previous.len / stride) return false;

    const size = std.math.mul(usize, capacity, stride) catch return error.OutOfMemory;
    const alignment = buffer.alignment;
    const address = @returnAddress();

    const next = if (previous.len != 0)
        allocator.rawRemap(previous, alignment, size, address)
    else
        null;

    const bytes = next orelse block: {
        const storage = allocator.rawAlloc(size, alignment, address) orelse return error.OutOfMemory;

        if (previous.len != 0) {
            const prefix = length * stride;

            @memcpy(storage[0..prefix], previous[0..prefix]);
            allocator.rawFree(previous, alignment, address);
        }

        break :block storage;
    };

    buffer.bytes = bytes[0..size];

    return true;
}

pub inline fn rowBufferBytes(target: *const anyopaque) []const u8 {
    const buffer: *const RowBuffer = @ptrCast(@alignCast(target));

    return buffer.bytes;
}

pub fn allocateRowStorage(allocator: std.mem.Allocator, resource: ?*const anyopaque, target: *const anyopaque, count: u64) std.mem.Allocator.Error!bool {
    const buffer = rowBuffer(target);
    const length = std.math.cast(usize, count) orelse return error.OutOfMemory;
    const size = std.math.mul(usize, length, buffer.stride) catch return error.OutOfMemory;

    std.debug.assert(buffer.bytes.len == 0);

    if (size == 0) return false;

    const owner = if (resource) |value| @import("column_set.zig").borrowAllocator(value) else allocator;
    const bytes = owner.rawAlloc(size, buffer.alignment, @returnAddress()) orelse return error.OutOfMemory;

    buffer.bytes = bytes[0..size];

    return true;
}

pub fn writeRowList(column: *const anyopaque, index: u64, source: *const anyopaque) IndexError!void {
    const output: *const RowBuffer = @ptrCast(@alignCast(source));
    const count = if (output.bytes.len == 0) 0 else output.bytes.len / output.stride;

    try writeRowListCount(column, index, source, count);
}

pub inline fn writeRowListCount(column: *const anyopaque, index: u64, source: *const anyopaque, count: u64) IndexError!void {
    const output = rowBuffer(source);

    try write([]const u8, column, index, output.bytes.ptr[0..@intCast(count)]);
}

pub fn writeNamedRowList(column: *const anyopaque, index: u64, source: *const anyopaque) IndexError!void {
    const output: *const []@import("rows.zig").NamedId = @ptrCast(@alignCast(source));

    try write([]const u8, column, index, @as([*]const u8, @ptrCast(output.ptr))[0..output.len]);
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

pub fn writeRow(target: *const anyopaque, index: u64, source: []const u8) IndexError!void {
    const output: *const RowBuffer = @ptrCast(@alignCast(target));
    const width = output.stride;

    if (index >= output.bytes.len / width or source.len != width) return error.IndexOutOfBounds;

    const offset = @as(usize, @intCast(index)) * width;

    @memcpy(output.bytes[offset..][0..width], source);
}

pub inline fn writeRowByteView(target: *const anyopaque, index: u64, source: []const u8) IndexError!void {
    try writeRow(target, index, std.mem.asBytes(&source));
}

pub fn writeRowByteField(target: *const anyopaque, index: u64, offset: u64, source: []const u8) IndexError!void {
    const output: *const RowBuffer = @ptrCast(@alignCast(target));
    const width = @sizeOf([]const u8);

    if (index >= output.bytes.len / output.stride or offset > output.stride or width > output.stride - offset) return error.IndexOutOfBounds;

    const first = @as(usize, @intCast(index)) * output.stride + @as(usize, @intCast(offset));

    @memcpy(output.bytes[first..][0..width], std.mem.asBytes(&source));
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

pub inline fn writeU32List(target: *const anyopaque, index: u64, value: []const u32) IndexError!void {
    return write([]const u32, target, index, value);
}

pub inline fn writeU64List(target: *const anyopaque, index: u64, value: []const u64) IndexError!void {
    return write([]const u64, target, index, value);
}

pub inline fn writeU32Lists(target: *const anyopaque, index: u64, value: []const []const u32) IndexError!void {
    return write([]const []const u32, target, index, value);
}

pub inline fn writeOptionalU32(target: *const anyopaque, index: u64, value: ?u32) IndexError!void {
    return write(?u32, target, index, value);
}

pub inline fn writeOptionalU8(target: *const anyopaque, index: u64, value: ?u8) IndexError!void {
    return write(?u8, target, index, value);
}

pub inline fn writeText(target: *const anyopaque, index: u64, value: []const u8) IndexError!void {
    return write([]const u8, target, index, value);
}

pub inline fn writeOptionalText(target: *const anyopaque, index: u64, value: ?[]const u8) IndexError!void {
    return write(?[]const u8, target, index, value);
}

pub inline fn writeTextList(target: *const anyopaque, index: u64, value: []const []const u8) IndexError!void {
    return write([]const []const u8, target, index, value);
}

pub inline fn writeRowRange(target: *const anyopaque, index: u64, storage: []const u8, width: u64, first: u64, count: u64) IndexError!void {
    const rows = storage.len / width;

    if (first > rows or count > rows - first) return error.IndexOutOfBounds;

    const start: usize = @intCast(first * width);

    // The destination's typed slice stores its length in rows.
    try write([]const u8, target, index, storage[start..][0..@intCast(count)]);
}

pub inline fn writeRowReference(target: *const anyopaque, index: u64, storage: []const u8, width: u64, row: ?u64) IndexError!void {
    const address: ?[*]const u8 = if (row) |position| block: {
        if (position >= storage.len / width) return error.IndexOutOfBounds;

        break :block storage.ptr + @as(usize, @intCast(position * width));
    } else null;

    try write(?[*]const u8, target, index, address);
}

pub inline fn writeOptionalTextList(target: *const anyopaque, index: u64, value: ?[]const []const u8) IndexError!void {
    return write(?[]const []const u8, target, index, value);
}

pub fn clearOptionalRowList(target: *const anyopaque, index: u64) IndexError!void {
    return write(?[]const u8, target, index, null);
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
