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
    fn bind(self: *RowBuffer, bytes: []u8) void {
        self.bytes = bytes;
        const count = bytes.len / self.stride;

        for (self.fields, self.columns) |field, *column| {
            column.* = .{
                .items = if (count == 0) bytes.ptr else bytes.ptr + field.offset,
                .count = count,
                .stride = self.stride,
                .width = field.width,
            };
        }
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

        pub fn bind(self: *Self, storage: []Row) void {
            self.buffer.bind(std.mem.sliceAsBytes(storage));
        }
    };
}

pub const RowGrowth = struct {
    target: *RowBuffer,
    reads: []ReadColumn,
    pub fn refresh(self: RowGrowth) void {
        const buffer = self.target;
        const count = buffer.bytes.len / buffer.stride;

        for (buffer.fields, self.reads) |field, *read| {
            read.* = .{ .bytes = buffer.bytes, .count = count, .stride = buffer.stride, .offset = field.offset };
        }
    }
};

pub fn refreshReads(target: *const anyopaque) void {
    const growth: *const RowGrowth = @ptrCast(@alignCast(target));

    growth.refresh();
}

pub fn growRows(allocator: std.mem.Allocator, target: *const anyopaque, used: u64) std.mem.Allocator.Error!u64 {
    const growth: *const RowGrowth = @ptrCast(@alignCast(target));
    const buffer = growth.target;
    const stride = buffer.stride;
    const length = std.math.cast(usize, used) orelse return error.OutOfMemory;

    std.debug.assert(length == buffer.bytes.len / stride);

    const minimum = std.math.add(usize, length, 1) catch return error.OutOfMemory;
    const capacity = minimum +| (minimum / 2 + @max(1, std.atomic.cache_line / stride));

    try reserve(allocator, buffer, length, capacity);

    growth.refresh();

    return capacity;
}

pub fn reserveRows(allocator: std.mem.Allocator, target: *const anyopaque, used: u64, count: u64) std.mem.Allocator.Error!void {
    const buffer: *RowBuffer = @ptrCast(@alignCast(@constCast(target)));
    const length = std.math.cast(usize, used) orelse return error.OutOfMemory;
    const capacity = std.math.cast(usize, count) orelse return error.OutOfMemory;

    return reserve(allocator, buffer, length, capacity);
}

fn reserve(allocator: std.mem.Allocator, buffer: *RowBuffer, used: usize, count: usize) std.mem.Allocator.Error!void {
    const previous = buffer.bytes;
    const stride = buffer.stride;

    std.debug.assert(used <= previous.len / stride);

    if (count <= previous.len / stride) return;

    const size = std.math.mul(usize, count, stride) catch return error.OutOfMemory;
    const alignment = buffer.alignment;
    const address = @returnAddress();

    const next = if (previous.len != 0)
        allocator.rawRemap(previous, alignment, size, address)
    else
        null;

    const bytes = next orelse block: {
        const storage = allocator.rawAlloc(size, alignment, address) orelse return error.OutOfMemory;

        if (previous.len != 0) {
            const prefix = used * stride;

            @memcpy(storage[0..prefix], previous[0..prefix]);
            allocator.rawFree(previous, alignment, address);
        }

        break :block storage;
    };

    buffer.bind(bytes[0..size]);
}

pub inline fn rowBufferBytes(target: *const anyopaque) []const u8 {
    const buffer: *const RowBuffer = @ptrCast(@alignCast(target));

    return buffer.bytes;
}

pub fn allocateRows(allocator: std.mem.Allocator, target: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const output: *RowBuffer = @ptrCast(@alignCast(@constCast(target)));
    const length = std.math.cast(usize, count) orelse return error.OutOfMemory;
    const size = std.math.mul(usize, length, output.stride) catch return error.OutOfMemory;

    std.debug.assert(output.bytes.len == 0);

    if (size == 0) return;

    const bytes = allocator.rawAlloc(size, output.alignment, @returnAddress()) orelse return error.OutOfMemory;

    output.bind(bytes[0..size]);
}

/// Publishes a newly allocated list in a slice field of its owning row.
pub fn allocateRowList(allocator: std.mem.Allocator, column: *const anyopaque, index: u64, target: *const anyopaque, count: u64) (std.mem.Allocator.Error || IndexError)!void {
    const output: *RowBuffer = @ptrCast(@alignCast(@constCast(target)));

    output.bytes = &.{};

    try allocateRows(allocator, target, count);
    try write([]const u8, column, index, output.bytes.ptr[0..@intCast(count)]);
}

pub fn writeRowList(column: *const anyopaque, index: u64, source: *const anyopaque) IndexError!void {
    const output: *const RowBuffer = @ptrCast(@alignCast(source));
    const count = if (output.bytes.len == 0) 0 else output.bytes.len / output.stride;

    try write([]const u8, column, index, output.bytes.ptr[0..count]);
}

pub fn moveRowList(column: *const anyopaque, index: u64, source: *const anyopaque) IndexError!void {
    try writeRowList(column, index, source);

    const output: *RowBuffer = @ptrCast(@alignCast(@constCast(source)));

    output.bind(&.{});
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
