const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const rule = @import("generated_rx_program_store_bind");
const Input = std.meta.Child(rule.Input);
const Slots = std.meta.Child(@FieldType(Input, "source"));
const Result = @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload;
const Progress = if (@typeInfo(Result) == .pointer) std.meta.Child(Result) else Result;

pub fn write(builder: *Builder, source: ir.StoreTable, target: []u32) Builder.Error!void {
    std.debug.assert(source.count() == target.len);

    if (target.len == 0) return;

    const incoming = zx.columns.view(Slots, source);
    var cursor: usize = 0;

    while (cursor < target.len) {
        const readable = std.mem.sliceAsBytes(builder.stores.readable.items);
        const writable = std.mem.sliceAsBytes(builder.stores.writable.items);
        const registered = zx.columns.view(Slots, builder.stores.view());

        const input: Input = .{
            .source = &incoming,
            .registered = &registered,
            .permissions = &.{ .readable = @ptrCast(&readable), .writable = @ptrCast(&writable) },
            .mapping = @ptrCast(&target),
            .first = cursor,
        };

        var buffer: [@sizeOf(Progress)]u8 align(@alignOf(Progress)) = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&buffer);
        const progress = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch return error.InvalidModule;

        switch (progress.status) {
            .Ready => return,
            .Conflict => return error.InvalidModule,
            .Append => {
                const slot: usize = @intCast(progress.next);
                target[slot] = try builder.appendStore(source.at(slot));
                cursor = slot + 1;
            },
        }
    }
}
