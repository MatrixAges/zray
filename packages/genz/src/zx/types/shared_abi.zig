const std = @import("std");
const zx = @import("zx");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const rows = @import("../../node/import_rows.zig");
const Lower = @import("../lower.zig");
const Cache = @import("cache.zig");
const generated = @import("generated_shared_abi");

pub fn build(self: *Lower, index: usize) Lower.Error!void {
    const Input = std.meta.Child(generated.Input);
    const Source = std.meta.Child(@FieldType(Input, "source"));
    const Columns = std.meta.Child(@FieldType(Input, "columns"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Source, "types")), self.program.types);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const source: Source = .{
        .types = &types,
        .names = self.type_names,
        .cached = view.slice(@FieldType(Source, "cached"), @as([]const node.ExpressionId, self.abi_types)),
        .root = @intCast(index),
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
    };

    const target = Cache.borrow(self);
    const tracked = target.touch(Cache.Touched(Columns));
    const columns = target.columns(Columns, &tracked);
    const input: Input = .{ .source = &source, .columns = &columns };

    const output = zx.columns.invoke(generated.executeValue, buffered.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    const Expressions = std.meta.Child(@FieldType(std.meta.Child(generated.Output), "expressions"));
    var expressions: Expressions = undefined;

    inline for (@typeInfo(Expressions).@"struct".field_names) |name| {
        @field(expressions, name) = @field(output.expressions, name);
    }

    const imported = if (self.type_names != null)
        rows.appendBorrowingText(self.allocator, &self.builder.nodes.expressions, &expressions)

    else
        rows.append(self.allocator, &self.builder.nodes.expressions, &expressions);

    imported catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };
}
