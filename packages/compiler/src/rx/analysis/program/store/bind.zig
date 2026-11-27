const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const Binding = @import("../../store.zig").Binding;
const rule = @import("generated_rx_program_store_bind");
const Input = std.meta.Child(rule.Input);
const Source = std.meta.Child(@FieldType(Input, "source"));
const Slots = std.meta.Child(@FieldType(Source, "slots"));
const Getters = std.meta.Child(@typeInfo(@FieldType(Source, "getters")).optional.child);

pub fn write(builder: *Builder, source: ir.StoreTable, target: []u32) Builder.Error!void {
    std.debug.assert(source.count() == target.len);

    const slots = zx.columns.view(Slots, source);

    return bind(builder, &.{ .slots = &slots, .getters = null }, target);
}

pub fn reads(builder: *Builder, getters: []const Binding, target: []u32) Builder.Error!void {
    std.debug.assert(getters.len == target.len);

    const paths = zx.memory.borrowTextColumn("path", getters);
    const types = zx.memory.borrowReadColumn(ir.TypeId, "type_id", getters);
    const incoming: Getters = .{ .paths = @ptrCast(&paths), .types = @ptrCast(&types), .count = getters.len };
    const empty = zx.columns.view(Slots, @as(ir.StoreTable, .{}));

    return bind(builder, &.{ .slots = &empty, .getters = &incoming }, target);
}

fn bind(builder: *Builder, source: *const Source, target_arg: []u32) Builder.Error!void {
    if (target_arg.len == 0) return;

    var buffer: [1024]u8 = undefined;
    var first = std.heap.BufferFirstAllocator.init(&buffer, builder.allocator);
    var scratch = std.heap.ArenaAllocator.init(first.allocator());

    defer scratch.deinit();

    const storage = &builder.stores;
    const existing = storage.paths.items.len;
    const registered = zx.columns.view(Slots, storage.view());

    const input: Input = .{
        .registered = &registered,
        .source = source,
        .count = target_arg.len,
    };

    const result = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    if (!result.compatible) return error.InvalidModule;
    if (existing + result.appended.len > std.math.maxInt(u32)) return error.OutOfMemory;

    @memcpy(storage.readable.items, result.readable[0..existing]);
    @memcpy(storage.writable.items, result.writable[0..existing]);

    if (result.appended.len != 0) {
        const total = existing + result.appended.len;

        inline for (@typeInfo(ir.StoreStorage).@"struct".field_names) |name| {
            try @field(storage, name).ensureTotalCapacity(builder.allocator, total);
        }

        errdefer {
            for (storage.paths.items[existing..]) |path| builder.allocator.free(path);

            inline for (@typeInfo(ir.StoreStorage).@"struct".field_names) |name| {
                @field(storage, name).items.len = existing;
            }
        }

        for (result.appended) |item| {
            const path = if (item.path.len == 0) "" else try builder.allocator.dupe(u8, item.path);

            storage.paths.appendAssumeCapacity(path);
            storage.types.appendAssumeCapacity(item.type_id);
            storage.handles.appendAssumeCapacity("");
            storage.readable.appendAssumeCapacity(item.readable);
            storage.writable.appendAssumeCapacity(item.writable);
        }
    }

    @memcpy(target_arg, result.mapping);
}
