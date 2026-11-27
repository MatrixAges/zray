const std = @import("std");
const zx = @import("zx");
pub const Error = std.mem.Allocator.Error || error{UnsupportedNodeType};

pub fn render(allocator: std.mem.Allocator, types: zx.ir.TypeTable, input_id: zx.ir.TypeId, output_id: zx.ir.TypeId) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var writer: zx.memory.ByteWriter = .{ .allocator = allocator };

    defer writer.deinit();

    const entry = @import("generated_node_napi");
    const Input = std.meta.Child(entry.Input);
    const Bases = std.meta.Child(@FieldType(Input, "bases"));
    const table = zx.ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), types);
    const bases: Bases = .{ .capture = null, .expression_base = 0, .statement_base = 0, .field_base = 0, .serial = 0 };
    const input: Input = .{ .types = &table, .input = @backingInt(input_id), .output = @backingInt(output_id), .bases = &bases };
    const output = zx.columns.invoke(entry.executeValue, arena.allocator(), &input) catch |err| return failure(err);

    switch (output.status) {
        .Unsupported => return error.UnsupportedNodeType,
        .Invalid => return error.OutOfMemory,
        .Ready => {},
    }

    try @import("../../../printer/module.zig").writeChunks(&writer, output.chunks);

    return writer.finish();
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid N-API module AST"),
    };
}
