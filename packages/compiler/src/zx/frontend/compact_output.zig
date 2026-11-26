const std = @import("std");
/// Scratch backing for generated parser runs. Releasing the arena returns its memory to the heap.
pub const scratch_backing = std.heap.smp_allocator;
const Error = std.mem.Allocator.Error;

pub fn retainSyntax(allocator: std.mem.Allocator, input: anytype) Error!@TypeOf(input) {
    std.debug.assert(input.diagnostic == null);

    const Syntax = std.meta.Child(@TypeOf(input));
    const output = try allocator.create(Syntax);

    output.* = input.*;

    try retainTables(allocator, output);
    try retainIndices(allocator, output, .{ "tokens", "comments" });

    if (@hasField(Syntax, "constants")) {
        if (input.function_name) |name| output.function_name = try cloneOne(allocator, name);

        try retainIndices(allocator, output, .{
            "imports", "import_names", "import_sources", "declarations", "members", "contracts",
        });

        output.constants = try retainConstants(allocator, input.constants);
    }

    return output;
}

fn retainTables(allocator: std.mem.Allocator, syntax: anytype) Error!void {
    inline for (.{ "types", "expressions", "blocks" }) |name| {
        const source = @field(syntax.*, name);
        const Table = std.meta.Child(@TypeOf(source));
        const target = try allocator.create(Table);

        target.* = source.*;

        try retainIndices(allocator, target, @typeInfo(Table).@"struct".field_names);

        @field(syntax.*, name) = target;
    }

    const order = try allocator.create(std.meta.Child(@TypeOf(syntax.type_order)));

    try @import("retention/order.zig").fill(allocator, syntax.types, order);

    syntax.type_order = order;
}

fn retainIndices(allocator: std.mem.Allocator, target: anytype, comptime fields: anytype) Error!void {
    inline for (fields) |name| {
        @field(target.*, name) = try retainRowSlice(allocator, @field(target.*, name));
    }
}

fn retainConstants(allocator: std.mem.Allocator, source: anytype) Error!@TypeOf(source) {
    if (source.len == 0) return &.{};

    const Element = std.meta.Child(@TypeOf(source));
    const Constant = std.meta.Child(Element);
    const pointers = try allocator.alloc(Element, source.len);
    const storage = try allocator.alloc(Constant, source.len);

    for (source, pointers, storage) |item, *pointer, *constant| {
        constant.* = item.*;
        constant.name = try cloneOne(allocator, item.name);
        constant.span = try cloneOne(allocator, item.span);

        try retainTables(allocator, constant);

        pointer.* = constant;
    }

    return pointers;
}

fn retainRowSlice(allocator: std.mem.Allocator, list: anytype) Error!@TypeOf(list) {
    if (list.len == 0) return &.{};

    const Element = std.meta.Child(@TypeOf(list));

    if (comptime @typeInfo(Element) != .pointer) return allocator.dupe(Element, list);

    const Row = std.meta.Child(Element);
    const pointers = try allocator.alloc(Element, list.len);
    const storage = try allocator.alloc(Row, list.len);

    for (list, pointers, storage) |source, *pointer, *row| {
        row.* = source.*;
        pointer.* = row;
    }

    inline for (@typeInfo(Row).@"struct".field_names) |field_name| {
        const Field = @FieldType(Row, field_name);

        comptime assertFlatOrSinglePointer(Field);

        if (comptime @typeInfo(Field) == .pointer) {
            const Sub = std.meta.Child(Field);

            comptime assertPlainValue(Sub);

            const nested = try allocator.alloc(Sub, list.len);

            for (storage, nested) |*row, *copy| {
                copy.* = @field(row.*, field_name).*;

                @field(row.*, field_name) = copy;
            }
        }
    }

    return pointers;
}

fn cloneOne(allocator: std.mem.Allocator, pointer: anytype) Error!@TypeOf(pointer) {
    const copy = try allocator.create(std.meta.Child(@TypeOf(pointer)));

    copy.* = pointer.*;

    return copy;
}

fn assertFlatOrSinglePointer(comptime Field: type) void {
    switch (@typeInfo(Field)) {
        .pointer => |info| {
            if (info.size != .one) @compileError("retained row field cannot be a slice or many-pointer");
        },
        .optional => |info| {
            if (@typeInfo(info.child) == .pointer) @compileError("retained row field cannot be an optional pointer");
        },
        else => {},
    }
}

fn assertPlainValue(comptime Value: type) void {
    inline for (@typeInfo(Value).@"struct".field_names) |field_name| {
        switch (@typeInfo(@FieldType(Value, field_name))) {
            .pointer, .optional => @compileError("retained sub-row cannot contain pointers or optionals"),
            else => {},
        }
    }
}
