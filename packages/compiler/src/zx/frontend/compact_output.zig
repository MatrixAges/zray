const std = @import("std");
/// Scratch backing for generated parser runs; a real heap so releasing the scratch arena returns its memory.
pub const scratch_backing = std.heap.smp_allocator;

pub fn retainSyntax(allocator: std.mem.Allocator, source: []const u8, value: anytype) std.mem.Allocator.Error!@TypeOf(value) {
    const Syntax = std.meta.Child(@TypeOf(value));
    const Types = @FieldType(Syntax, "types");
    const output = try allocator.create(Syntax);

    inline for (@typeInfo(Syntax).@"struct".field_names) |name| {
        const field = @field(value.*, name);

        @field(output.*, name) = if (comptime std.mem.eql(u8, name, "tokens") or std.mem.eql(u8, name, "comments"))
            try allocator.dupe(std.meta.Child(@TypeOf(field)), field)
        else
            try clone(Types, @TypeOf(field), allocator, source, field);
    }

    return output;
}

fn clone(comptime Types: type, comptime T: type, allocator: std.mem.Allocator, source: []const u8, value: T) std.mem.Allocator.Error!T {
    if (comptime !hasPointers(T)) return value;

    if (T == Types) {
        const Tree = std.meta.Child(Types);
        const target = try allocator.create(Tree);

        inline for (@typeInfo(Tree).@"struct".field_names) |name| {
            const field = @field(value.*, name);

            @field(target.*, name) = try allocator.dupe(std.meta.Child(@TypeOf(field)), field);
        }

        return target;
    }

    switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .one => {
                const target = try allocator.create(info.child);

                target.* = try clone(Types, info.child, allocator, source, value.*);

                return target;
            },
            .slice => {
                if (info.child == u8 and borrowed(source, value)) return value;
                if (comptime !hasPointers(info.child)) return allocator.dupe(info.child, value);

                const target = try allocator.alloc(info.child, value.len);

                for (value, target) |item, *slot| slot.* = try clone(Types, info.child, allocator, source, item);

                return target;
            },
            else => @compileError("unsupported generated parser pointer: " ++ @typeName(T)),
        },
        .optional => |info| return if (value) |item| try clone(Types, info.child, allocator, source, item) else null,
        .@"struct" => |info| {
            var target: T = undefined;

            inline for (info.field_names) |name| @field(target, name) = try clone(Types, @FieldType(T, name), allocator, source, @field(value, name));

            return target;
        },
        .array => |info| {
            var target: T = undefined;

            for (value, &target) |item, *slot| slot.* = try clone(Types, info.child, allocator, source, item);

            return target;
        },
        else => @compileError("unsupported generated parser value: " ++ @typeName(T)),
    }
}

fn borrowed(source: []const u8, text: []const u8) bool {
    if (text.len == 0) return true;

    const start = @intFromPtr(source.ptr);
    const first = @intFromPtr(text.ptr);

    return first >= start and first + text.len <= start + source.len;
}

fn hasPointers(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |info| hasPointers(info.child),
        .array => |info| hasPointers(info.child),
        .@"struct" => |info| inline for (info.field_names) |name| {
            if (hasPointers(@FieldType(T, name))) break true;
        } else false,
        else => false,
    };
}
