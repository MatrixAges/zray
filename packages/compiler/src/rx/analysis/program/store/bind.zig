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
const Tail = std.meta.Child(@FieldType(Input, "tail"));

const Frame = struct {
    builder: *Builder,
    registered: Slots = undefined,
    paths: [][]const u8 = undefined,
    types: []u32 = undefined,
    handles: [][]const u8 = undefined,
    readable: []bool = undefined,
    writable: []bool = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

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

fn bind(builder: *Builder, source: *const Source, target: []u32) Builder.Error!void {
    if (target.len == 0) return;

    var frame: Frame = .{ .builder = builder };
    const storage = &builder.stores;
    const slots = zx.memory.borrowColumnLengths(storage);
    const lengths: zx.memory.ColumnLengths = &slots;

    const tail: Tail = .{
        .paths = @ptrCast(&frame.paths),
        .types = @ptrCast(&frame.types),
        .handles = @ptrCast(&frame.handles),
        .readable = @ptrCast(&frame.readable),
        .writable = @ptrCast(&frame.writable),
        .lengths = @ptrCast(&lengths),
    };

    const input: Input = .{
        .frame = @ptrCast(&frame),
        .allocator = @ptrCast(&builder.allocator),
        .source = source,
        .registered = &frame.registered,
        .permissions = &.{
            .readable = @ptrCast(&storage.readable.items),
            .writable = @ptrCast(&storage.writable.items),
        },
        .mapping = @ptrCast(&target),
        .tail = &tail,
        .count = target.len,
    };

    return rule.executeIn(std.mem.Allocator.failing, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModule,
    };
}

pub fn borrowProgramStoreSlots(handle: *const anyopaque) void {
    const frame = Frame.borrow(handle);

    frame.registered = zx.columns.view(Slots, frame.builder.stores.view());
}

pub fn reserveProgramStoreSlot(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const builder = frame.builder;
    const storage = &builder.stores;

    inline for (@typeInfo(ir.StoreStorage).@"struct".field_names) |name| {
        try @field(storage, name).ensureUnusedCapacity(builder.allocator, 1);

        @field(frame, name) = @field(storage, name).unusedCapacitySlice()[0..1];
    }
}

pub fn requireProgramStoreMatch(compatible: bool) error{InvalidModule}!void {
    if (!compatible) return error.InvalidModule;
}
