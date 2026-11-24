const std = @import("std");
const zx = @import("zx");
const Table = zx.ir.FunctionTable;
const rule = @import("generated_function_prefix");
const Input = std.meta.Child(rule.Input);
const Column = std.meta.Child(std.meta.Elem(@FieldType(Input, "columns")));

const Pair = union {
    bytes: info("bytes"),
    ids: info("ids"),
    views: info("views"),
    optional_views: info("optional_views"),
};

fn info(comptime name: []const u8) type {
    return std.meta.Child(@typeInfo(@FieldType(Column, name)).optional.child);
}

const names = @typeInfo(Table).@"struct".field_names;

pub const Storage = struct {
    pairs: [names.len]Pair = undefined,
    views: [names.len]Column = undefined,
    columns: [names.len]*const Column = undefined,
    pub fn bind(self: *Storage, table: *const Table, prefix: *const Table, limit: usize, strict: bool) Input {
        var used: usize = 0;

        inline for (names) |name| {
            const left = @field(table, name);
            const right = @field(prefix, name);

            if (left.ptr != right.ptr) {
                self.views[used] = borrow(&self.pairs[used], left, right);
                self.columns[used] = &self.views[used];
                used += 1;
            }
        }

        return .{ .columns = self.columns[0..used], .limit = limit, .strict = strict };
    }
};

pub noinline fn scan(table: *const Table, prefix: *const Table, limit: usize, strict: bool) usize {
    var storage: Storage = .{};
    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const input = storage.bind(table, prefix, limit, strict);

    return @intCast(zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable);
}

fn borrow(storage: *Pair, left: anytype, right: @TypeOf(left)) Column {
    const Element = std.meta.Elem(@TypeOf(left));
    var column: Column = .{ .bytes = null, .ids = null, .views = null, .optional_views = null };

    if (Element == ?u32) {
        storage.* = .{ .ids = .{ .left = left, .right = right } };
        column.ids = &storage.ids;
    } else if (comptime @typeInfo(Element) == .optional) {
        const T = @typeInfo(Element).optional.child;

        if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .slice) @compileError("Unsupported optional column");

        storage.* = .{ .optional_views = .{ .left = @ptrCast(left), .right = @ptrCast(right) } };
        column.optional_views = &storage.optional_views;
    } else if (comptime @typeInfo(Element) == .pointer and @typeInfo(Element).pointer.size == .slice) {
        storage.* = .{ .views = .{ .left = @ptrCast(left), .right = @ptrCast(right) } };
        column.views = &storage.views;
    } else {
        const mask: u64 = comptime switch (@typeInfo(Element)) {
            .bool, .@"enum" => if (@sizeOf(Element) == 1) std.math.maxInt(@Int(.unsigned, @bitSizeOf(Element))) else @compileError("Unsupported tag size"),
            .int, .pointer => if (@bitSizeOf(Element) == 8 * @sizeOf(Element)) std.math.maxInt(u8) else @compileError("Unsupported padded column"),
            else => @compileError("Unsupported function column"),
        };

        storage.* = .{ .bytes = .{ .left = std.mem.sliceAsBytes(left), .right = std.mem.sliceAsBytes(right), .width = @sizeOf(Element), .mask = mask } };
        column.bytes = &storage.bytes;
    }

    return column;
}
