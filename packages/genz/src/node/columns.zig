const std = @import("std");
const schema = @import("schema.zig");
const view = @import("view.zig");

pub fn Columns(comptime Value: type, comptime Layout: type, comptime path: []const u8) type {
    if (@typeInfo(Value) != .@"struct") {
        const Element = if (Layout == void or Value == void) Value else schema.element(Layout, path);

        return Scalar(Value, Element);
    }

    const names = @typeInfo(Value).@"struct".field_names;

    const Fields = blk: {
        var types: [names.len]type = undefined;

        for (names, &types) |name, *target| {
            const field = if (path.len == 0) name else path ++ "_" ++ name;

            target.* = Columns(@FieldType(Value, name), Layout, field);
        }

        break :blk @Struct(.auto, null, names, &types, &@splat(.{}));
    };

    return struct {
        const Self = @This();
        fields: Fields,
        pub fn init() Self {
            var result: Self = undefined;

            inline for (names) |name| @field(result.fields, name) = .init();

            return result;
        }
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            inline for (names) |name| try @field(self.fields, name).reserve(allocator, additional);
        }

        pub fn append(self: *Self, value: Value) void {
            inline for (names) |name| @field(self.fields, name).append(@field(value, name));
        }
        pub fn get(self: *const Self, index: usize) Value {
            var result: Value = undefined;

            inline for (names) |name| @field(result, name) = @field(self.fields, name).get(index);

            return result;
        }
        pub fn count(self: *const Self) usize {
            return @field(self.fields, names[0]).count();
        }
    };
}

fn Scalar(comptime Value: type, comptime Element: type) type {
    comptime view.compatible(Value, Element);

    return struct {
        const Self = @This();

        values: std.ArrayList(Element) = .empty,
        pub fn init() Self {
            return .{};
        }
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            try self.values.ensureUnusedCapacity(allocator, additional);
        }

        pub fn append(self: *Self, value: Value) void {
            self.values.appendAssumeCapacity(if (Value == Element) value else @as(*const Element, @ptrCast(&value)).*);
        }

        pub fn get(self: *const Self, index: usize) Value {
            const item = &self.values.items[index];

            return if (Value == Element) item.* else @as(*const Value, @ptrCast(item)).*;
        }
        pub fn count(self: *const Self) usize {
            return self.values.items.len;
        }
    };
}
