const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const Binding = @import("../../store.zig").Binding;

pub fn write(builder: *Builder, source: ir.StoreTable, target: []u32) Builder.Error!void {
    std.debug.assert(source.count() == target.len);

    if (target.len == 0) return;

    const rule = @import("generated_rx_program_store_bind");
    const Input = std.meta.Child(rule.Input);
    const incoming = zx.columns.view(std.meta.Child(@FieldType(Input, "source")), source);

    return bind(rule, builder, source, &incoming, target);
}

pub fn reads(builder: *Builder, getters: []const Binding, target: []u32) Builder.Error!void {
    std.debug.assert(getters.len == target.len);

    const rule = @import("generated_rx_program_read_slots");
    const Input = std.meta.Child(rule.Input);
    const paths = zx.memory.borrowTextColumn("path", getters);
    const types = zx.memory.borrowReadColumn(ir.TypeId, "type_id", getters);
    const incoming: std.meta.Child(@FieldType(Input, "source")) = .{ .paths = @ptrCast(&paths), .types = @ptrCast(&types), .count = getters.len };

    return bind(rule, builder, getters, &incoming, target);
}

fn bind(comptime rule: type, builder: *Builder, source: anytype, incoming: anytype, target: []u32) Builder.Error!void {
    const Input = std.meta.Child(rule.Input);
    const Slots = std.meta.Child(@FieldType(Input, "registered"));
    const Result = @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload;
    const Progress = if (@typeInfo(Result) == .pointer) std.meta.Child(Result) else Result;
    var cursor: usize = 0;

    while (cursor < target.len) {
        const readable = std.mem.sliceAsBytes(builder.stores.readable.items);
        const writable = std.mem.sliceAsBytes(builder.stores.writable.items);
        const registered = zx.columns.view(Slots, builder.stores.view());

        const input: Input = .{
            .source = incoming,
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
                const row: usize = @intCast(progress.next);
                const slot = if (comptime @TypeOf(source) == ir.StoreTable) source.at(row) else source[row].readSlot();

                target[row] = try builder.appendStore(slot);
                cursor = row + 1;
            },
        }
    }
}
