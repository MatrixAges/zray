const std = @import("std");
const zx = @import("zx");
const ir = @import("zx").ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const module = @import("../../node/import_module.zig");
const Lower = @import("../lower.zig");
const Cache = @import("cache.zig");
const generated = @import("generated_shared_abi");
const publish = @import("generated_publish_shared_abi");

pub fn build(self: *Lower, index: usize) Lower.Error!void {
    const Input = std.meta.Child(generated.Input);
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), self.program.types);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var buffered = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const input: Input = .{
        .types = &types,
        .names = self.type_names,
        .cached = view.slice(@FieldType(Input, "cached"), @as([]const node.ExpressionId, self.abi_types)),
        .root = @intCast(index),
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
    };

    const output = zx.columns.invoke(generated.executeValue, buffered.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    const Output = std.meta.Child(generated.Output);

    const imported = if (self.type_names != null)
        module.appendBorrowingText(self.allocator, self.builder.nodes, Output, output)

    else
        module.append(self.allocator, self.builder.nodes, Output, output);

    imported catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAst => unreachable,
    };

    const Publication = std.meta.Child(publish.Input);
    const Columns = std.meta.Child(@FieldType(Publication, "columns"));
    const target = Cache.borrow(self);
    const tracked = target.touch(Cache.Touched(Columns));
    const columns = target.columns(Columns, &tracked);

    const publication: Publication = .{
        .nodes = &.{ .ids = output.ids, .values = output.values, .layouts = output.layouts },
        .columns = &columns,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(publish.executeValue, fixed.allocator(), &publication) catch unreachable;
}
