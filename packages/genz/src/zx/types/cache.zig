const std = @import("std");
const zx = @import("zx");
const Lower = @import("../lower.zig");
const payloads = @import("../../node/import_payloads.zig");

/// Cached handles refer only to expressions that were committed to the AST.
pub fn publish(lower: *Lower, comptime Output: type, output: anytype, comptime borrow_text: bool) Lower.Error!void {
    if (!output.valid) return error.OutOfMemory;

    const entry = @import("generated_commit_shared_types");
    const Input = std.meta.Child(entry.Input);
    const Columns = std.meta.Child(@FieldType(Input, "columns"));
    const Bound = std.meta.Child(@FieldType(Input, "ast"));
    const Expressions = std.meta.Child(@FieldType(Output, "expressions"));
    const expressions = zx.columns.view(Expressions, output.expressions);
    const target = &lower.builder.nodes.expressions;
    var binding: payloads.Binding(@TypeOf(target), Expressions, .dense) = .{};
    const ast = binding.bind(Bound, &lower.allocator, target, &expressions, true, borrow_text);
    const state = @hasField(Output, "entries");

    const rows: Columns = .{
        .abi_types = @ptrCast(lower.abi_types),
        .state_types = @ptrCast(lower.state_types),
        .views = @ptrCast(lower.view_types),
        .track_touched = if (lower.type_scratch) |storage| storage.columns.touched.len != 0 else false,
    };

    var arena = std.heap.ArenaAllocator.init(lower.allocator);

    defer arena.deinit();

    var scratch_buf: [1024]u8 = undefined;
    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());

    const input: Input = .{
        .ast = &ast,
        .columns = &rows,
        .abi = if (state) null else &.{ .ids = output.ids },
        .state = if (state) output.entries else null,
    };

    const result = zx.columns.invoke(entry.executeValue, fallback.allocator(), &input) catch |err| {
        binding.rollback(&lower.allocator);

        return switch (payloads.failure(err)) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidAst => unreachable,
        };
    };

    payloads.appendHeaders(target, expressions.tags, result.ast);

    switch (result.ast.check) {
        .Valid => {},
        .Invalid => unreachable,
        .Exhausted => return error.OutOfMemory,
    }

    if (lower.type_scratch) |storage| {
        if (result.touched.len != 0) {
            const start: usize = @intCast(storage.dirty);

            @memcpy(storage.columns.touched[start .. start + result.touched.len], result.touched);

            storage.dirty += @intCast(result.touched.len);
        }
    }

    if (comptime state) {
        for (output.entries) |item| {
            const index = item.request.id;

            switch (item.request.mode) {
                .Abi => {
                    lower.abi_types[index] = @fromBackingInt(item.value);
                    lower.abi_layouts[index] = @fromBackingInt(item.layout);
                },
                .State => {
                    lower.state_types[index] = @fromBackingInt(item.value);
                    lower.state_layouts[index] = @fromBackingInt(item.layout);
                },
                else => lower.view_types[index] = @fromBackingInt(item.value),
            }
        }
    } else {
        for (output.ids, output.values, output.layouts) |row, value, layout| {
            lower.abi_types[row] = @fromBackingInt(value);
            lower.abi_layouts[row] = @fromBackingInt(layout);
        }
    }
}
