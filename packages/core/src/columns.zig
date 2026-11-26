const std = @import("std");
pub const storage = @import("columns/storage.zig");

pub fn appendRows(target: anytype, allocator: std.mem.Allocator, source: @TypeOf(target.slice()), start: usize) std.mem.Allocator.Error!void {
    const count = source.len - start;

    if (count == 0) return;

    const first = target.len;

    try target.resize(allocator, first + count);

    const destination = target.slice();

    inline for (std.enums.values(@TypeOf(target.*).Field)) |field| {
        @memcpy(destination.items(field)[first..], source.items(field)[start..]);
    }
}

pub fn columns(comptime Target: type, value: anytype) Target {
    @setEvalBranchQuota(100_000);

    const Source = @TypeOf(value);
    const names = @typeInfo(Target).@"struct".field_names;

    if (names.len != @typeInfo(Source).@"struct".field_names.len) @compileError("Incompatible column count");

    var result: Target = undefined;

    inline for (names) |name| {
        const Field = @FieldType(Target, name);
        const source = @field(value, name);

        @field(result, name) = slice(Field, source);
    }

    return result;
}

pub fn slice(comptime Target: type, source: anytype) Target {
    @setEvalBranchQuota(100_000);

    if (Target == @TypeOf(source)) return source;

    comptime compatible(Target, @TypeOf(source));

    const Child = @typeInfo(Target).pointer.child;

    return @as([*]const Child, @ptrCast(source.ptr))[0..source.len];
}

pub fn pointer(comptime Target: type, source: anytype) Target {
    @setEvalBranchQuota(100_000);

    if (Target == @TypeOf(source)) return source;

    comptime compatible(Target, @TypeOf(source));

    return @ptrCast(source);
}

/// The source rows outlive the pointer table and every value borrowed through it.
pub fn pointers(comptime Target: type, allocator: std.mem.Allocator, source: anytype) std.mem.Allocator.Error!Target {
    const target = @typeInfo(Target);

    if (target != .pointer or target.pointer.size != .slice or !target.pointer.attrs.@"const") @compileError("Borrowed row pointers require a read-only slice");

    const Element = target.pointer.child;
    const element = @typeInfo(Element);

    if (element != .pointer or element.pointer.size != .one or !element.pointer.attrs.@"const") @compileError("Borrowed rows require read-only pointers");

    const result = try allocator.alloc(Element, source.len);

    for (source, result) |*row, *value| value.* = pointer(Element, row);

    return result;
}

pub fn view(comptime Target: type, value: anytype) Target {
    return viewMode(Target, value, false);
}

fn viewMode(comptime Target: type, value: anytype, comptime borrowed: bool) Target {
    @setEvalBranchQuota(100_000);

    if (Target == @TypeOf(value)) return value;

    const target = @typeInfo(Target);

    if (target == .optional and @typeInfo(@TypeOf(value)) == .optional) {
        return if (value) |payload| viewMode(target.optional.child, payload, borrowed) else null;
    }

    if (target == .pointer) {
        if (target.pointer.size != .slice) return pointer(Target, value);

        const source = @TypeOf(value);

        if (@typeInfo(source) == .@"struct" and @hasField(source, "items") and @hasField(source, "storage")) return slice(Target, value.items);

        return slice(Target, value);
    }

    const source_pointer = @typeInfo(@TypeOf(value));

    if (borrowed and target == .@"struct" and source_pointer == .pointer and source_pointer.pointer.size == .slice and
        @hasField(Target, "items") and @hasField(Target, "storage"))
    {
        return .{ .items = slice(@FieldType(Target, "items"), value), .storage = .plain };
    }

    if (target == .@"struct") {
        const source = if (@typeInfo(@TypeOf(value)) == .pointer) value.* else value;
        var result: Target = undefined;

        inline for (target.@"struct".field_names) |name| {
            @field(result, name) = if (comptime std.mem.eql(u8, name, "zx_origin")) origin: {
                if (!borrowed or @typeInfo(@TypeOf(value)) != .pointer) break :origin null;

                const Origin = @typeInfo(@FieldType(Target, name)).optional.child;

                break :origin pointer(Origin, value);
            } else viewMode(@FieldType(Target, name), @field(source, name), borrowed);
        }

        return result;
    }

    comptime compatible(Target, @TypeOf(value));

    return @fromBackingInt(@backingInt(value));
}

/// The source descriptor stays unchanged and outlives every use of the borrowed view.
pub fn borrow(comptime Target: type, source: anytype) Target {
    const info = @typeInfo(@TypeOf(source));

    if (info != .pointer or info.pointer.size != .one or !info.pointer.attrs.@"const") @compileError("Borrowed columns require a const descriptor pointer");

    return viewMode(Target, source, true);
}

/// Borrows an ABI descriptor for the synchronous value entry; the source outlives result references.
pub inline fn invoke(comptime function: anytype, allocator: std.mem.Allocator, source: anytype) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
    const Parameter = @typeInfo(@TypeOf(function)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Value = if (indirect) std.meta.Child(Parameter) else Parameter;
    const value = borrow(Value, source);

    return function(allocator, if (indirect) &value else value);
}

fn compatible(comptime Target: type, comptime Source: type) void {
    if (Target == Source) return;

    const target = @typeInfo(Target);
    const source = @typeInfo(Source);

    // Each independently generated ABI module declares its own nominal handle types.
    if (target == .@"opaque" or source == .@"opaque") {
        const name = @typeName(Target);

        if (target != .@"opaque" or source != .@"opaque" or
            !std.mem.startsWith(u8, name, "types.zx_type_") or !std.mem.eql(u8, name, @typeName(Source)))
        {
            @compileError("Incompatible opaque column: " ++ @typeName(Source) ++ " -> " ++ name);
        }

        return;
    }

    if (@sizeOf(Target) != @sizeOf(Source) or @alignOf(Target) != @alignOf(Source)) @compileError("Incompatible column representation");

    if (target == .optional and source == .optional) {
        return compatible(target.optional.child, source.optional.child);
    }

    if (target == .pointer and source == .pointer) {
        const left = target.pointer;
        const right = source.pointer;
        const mutable_opaque = left.size == .one and !left.attrs.@"const" and !right.attrs.@"const" and @typeInfo(left.child) == .@"opaque" and @typeInfo(right.child) == .@"opaque";

        if ((left.size != .slice and left.size != .one) or left.size != right.size or left.sentinel_ptr != null or right.sentinel_ptr != null or (!mutable_opaque and (!left.attrs.@"const" or !right.attrs.@"const")) or !std.meta.eql(left.attrs, right.attrs)) @compileError("Incompatible column pointer");

        return compatible(left.child, right.child);
    }

    if (target == .@"struct" and source == .@"struct") {
        const names = target.@"struct".field_names;

        if (target.@"struct".layout != source.@"struct".layout or names.len != source.@"struct".field_names.len) @compileError("Incompatible column descriptor");

        inline for (names) |name| {
            if (!@hasField(Source, name)) @compileError("Incompatible column descriptor field");
            if (@offsetOf(Target, name) != @offsetOf(Source, name)) @compileError("Incompatible column descriptor offset");

            compatible(@FieldType(Target, name), @FieldType(Source, name));
        }

        return;
    }

    if (target != .@"enum" or source != .@"enum" or target.@"enum".tag_type != source.@"enum".tag_type) {
        @compileError("Incompatible column representation: " ++ @typeName(Source) ++ " -> " ++ @typeName(Target));
    }

    const expected = source.@"enum".field_names;
    const actual = target.@"enum".field_names;

    if (expected.len != actual.len) @compileError("Incompatible column enum count");

    inline for (expected, actual) |left, right| {
        if (!std.mem.eql(u8, left, right) or @backingInt(@field(Source, left)) != @backingInt(@field(Target, right))) @compileError("Incompatible column enum mapping");
    }
}

/// Copies every column of a borrowed table into the allocator, including the bytes of text columns.
pub fn own(allocator: std.mem.Allocator, source: anytype, replacements: anytype) std.mem.Allocator.Error!@TypeOf(source) {
    @setEvalBranchQuota(100_000);

    const Table = @TypeOf(source);
    var result: Table = undefined;

    inline for (@typeInfo(Table).@"struct".field_names) |name| {
        if (comptime @hasField(@TypeOf(replacements), name)) {
            @field(result, name) = @field(replacements, name);
        } else {
            const values = @field(source, name);
            const Child = @typeInfo(@TypeOf(values)).pointer.child;
            const owned = try allocator.dupe(Child, values);

            if (comptime Child == []const u8) {
                for (owned) |*text| text.* = try allocator.dupe(u8, text.*);
            }

            @field(result, name) = owned;
        }
    }

    return result;
}

/// Bridges structurally matching values across distinct generated ABI nominal types.
pub fn bridge(comptime Target: type, allocator: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!Target {
    @setEvalBranchQuota(100_000);

    if (Target == @TypeOf(value)) return value;

    return switch (@typeInfo(Target)) {
        .pointer => |ptr| switch (ptr.size) {
            .one => blk: {
                if (comptime @typeInfo(ptr.child) == .@"opaque") break :blk @ptrCast(value);

                const copy = try allocator.create(ptr.child);
                const inner = if (@typeInfo(@TypeOf(value)) == .pointer) value.* else value;
                copy.* = try bridge(ptr.child, allocator, inner);

                break :blk copy;
            },
            .slice => blk: {
                if (comptime ptr.child == std.meta.Elem(@TypeOf(value))) break :blk value;
                if (value.len == 0) break :blk &.{};

                const copy = try allocator.alloc(ptr.child, value.len);

                for (copy, value) |*dst, item| dst.* = try bridge(ptr.child, allocator, item);

                break :blk copy;
            },
            else => @compileError("Unsupported bridged pointer size"),
        },
        .optional => |opt| if (value) |inner| try bridge(opt.child, allocator, inner) else null,
        .@"struct" => |info| blk: {
            const inner = if (@typeInfo(@TypeOf(value)) == .pointer) value.* else value;
            var result: Target = undefined;

            inline for (info.field_names) |name| {
                @field(result, name) = if (comptime std.mem.eql(u8, name, "zx_origin"))
                    null
                else
                    try bridge(@FieldType(Target, name), allocator, @field(inner, name));
            }

            break :blk result;
        },
        .@"enum" => @fromBackingInt(@backingInt(value)),
        else => value,
    };
}
