const std = @import("std");
const options = @import("parser_options");
const memory = @import("zx").memory;
const borrow = @import("canonical/borrow.zig");

pub fn valid(allocator: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!bool {
    if (comptime options.generated_parser) {
        const generated = @import("generated_ir_body");
        const Input = std.meta.Child(generated.Input);
        const Body = std.meta.Child(@FieldType(Input, "body"));
        const stores = borrow.pointer(@FieldType(Body, "stores"), &value.stores);
        const symbols = borrow.pointer(@FieldType(Body, "symbols"), &value.symbols);
        const expressions = borrow.pointer(@FieldType(Body, "expressions"), &value.expressions);
        const control = borrow.pointer(@FieldType(Body, "control"), value.body.control);
        const body: Body = .{ .stores = stores, .symbols = symbols, .expressions = expressions, .control = control, .root = if (value.body.root) |root| @backingInt(root) else null };
        var arena = std.heap.ArenaAllocator.init(allocator);

        defer arena.deinit();

        const Workspace = std.meta.Child(@FieldType(Input, "workspace"));
        var scratch: memory.U32Scratch = .{ .allocator = arena.allocator() };

        defer scratch.deinit();

        return generated.execute(&arena, &.{
            .body = &body,
            .max_offset = std.math.maxInt(usize),
            .workspace = &scratch.borrow(Workspace, true),
        }) catch |err| switch (err) {
            error.OutOfMemory, error.Overflow => return error.OutOfMemory,
            else => return false,
        };
    } else {
        return value.stores.validStructure() and try value.body.validStructure(allocator) and value.expressions.validStructure() and value.symbols.validStructure();
    }
}
