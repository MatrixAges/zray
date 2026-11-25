const std = @import("std");
/// Scratch backing for generated parser runs. Releasing the arena returns its memory to the heap.
pub const scratch_backing = std.heap.smp_allocator;
const Error = std.mem.Allocator.Error;

pub fn retainSyntax(allocator: std.mem.Allocator, input: anytype) Error!@TypeOf(input) {
    const Syntax = std.meta.Child(@TypeOf(input));
    const output = try allocator.create(Syntax);

    output.* = input.*;

    try retainTables(allocator, output);
    try retainIndices(allocator, output, .{ "tokens", "comments" });

    if (@hasField(Syntax, "constants")) {
        try retainIndices(allocator, output, .{
            "imports", "import_names", "import_sources", "declarations", "members", "contracts",
        });

        const constants = try allocator.alloc(std.meta.Child(@TypeOf(input.constants)), input.constants.len);

        for (input.constants, constants) |source, *target| {
            const constant = try allocator.create(std.meta.Child(@TypeOf(source)));
            constant.* = source.*;

            try retainTables(allocator, constant);

            target.* = constant;
        }

        output.constants = constants;
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
        const list = @field(target.*, name);

        @field(target.*, name) = try allocator.dupe(std.meta.Child(@TypeOf(list)), list);
    }
}
