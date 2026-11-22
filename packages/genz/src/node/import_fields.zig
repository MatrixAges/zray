const std = @import("std");
const zx = @import("zx");
const node = @import("../node.zig");
const payloads = @import("import_payloads.zig");
const transfer = zx.memory.column_transfer;
const Fields = @import("stored.zig").Fields;
const generated = @import("genz_options").generated_analysis;
pub const Error = std.mem.Allocator.Error || error{InvalidAst};

/// Imports complete field columns and owns their text in the target allocator.
pub fn append(allocator: std.mem.Allocator, target: anytype, source: anytype) Error!void {
    _ = try appendFields(allocator, target, source, false);
}

/// Text must outlive the target; field descriptors receive owned column storage.
pub fn appendBorrowingText(allocator: std.mem.Allocator, target: anytype, source: anytype) Error!Fields {
    return appendFields(allocator, target, source, true);
}

pub fn appendObject(allocator: std.mem.Allocator, target: anytype, source: anytype) std.mem.Allocator.Error!void {
    if (generated) {
        const default_value: ?node.ExpressionId = null;
        const comptime_parameter = false;

        const columns = [_]transfer.Column{
            transfer.bind(&target.fields.name.values, source.name, false, true),
            transfer.bind(&target.fields.value.values, source.value, false, true),
            transfer.repeat(&target.fields.default_value.values, &default_value),
            transfer.repeat(&target.fields.comptime_parameter.values, &comptime_parameter),
        };

        return payloads.Plain.append(allocator, &columns, source.name.len, target.count(), true) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAst => unreachable,
        };
    }

    std.debug.assert(source.name.len == source.value.len);

    if (source.name.len > std.math.maxInt(u32) - target.count()) return error.OutOfMemory;
    try target.reserve(allocator, source.name.len);

    for (source.name, source.value) |name, value| target.append(node.Field{
        .name = name,
        .value = @fromBackingInt(value),
    });
}

/// Materializes standalone fields; borrowed text must outlive the returned descriptors.
pub fn materializeBorrowingText(allocator: std.mem.Allocator, source: anytype) Error![]const node.Field {
    if (generated) {
        const entry = @import("generated_node_materialize_fields");
        const Input = std.meta.Child(entry.Input);
        const Target = std.meta.Child(@FieldType(Input, "target"));

        const Output = zx.memory.RowOutput(node.Field, Target, .{
            .name = &.{"name"},
            .value = &.{"value"},
            .default_value = &.{"default_value"},
            .comptime_parameter = &.{"comptime_parameter"},
        });

        var output: Output = undefined;

        output.init();

        const fields = zx.columns.view(std.meta.Child(@FieldType(Input, "source")), source);

        const input: Input = .{
            .source = &fields,
            .target = &output.view,
            .rows = @ptrCast(&output.buffer),
            .allocator = @ptrCast(&allocator),
        };

        var fixed = std.heap.FixedBufferAllocator.init(&.{});
        const valid = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch |err| return payloads.failure(err);

        if (!valid) return error.InvalidAst;

        return output.rows();
    }

    const count = source.name.len;

    inline for (@typeInfo(std.meta.Child(@TypeOf(source))).@"struct".field_names) |name| {
        if (@field(source, name).len != count) return error.InvalidAst;
    }

    const result = try allocator.alloc(node.Field, count);

    for (result, 0..) |*item, index| item.* = .{
        .name = source.name[index],
        .value = @fromBackingInt(source.value[index]),
        .default_value = if (source.default_value[index]) |id| @fromBackingInt(id) else null,
        .comptime_parameter = source.comptime_parameter[index],
    };

    return result;
}

fn appendFields(allocator: std.mem.Allocator, target: anytype, source: anytype, comptime borrow_text: bool) Error!Fields {
    const count = source.name.len;

    if (generated) {
        const first = target.count();
        const columns = bindColumns(target, source, borrow_text);

        try payloads.Plain.append(allocator, &columns, count, first, borrow_text);

        return .{ .start = @intCast(first), .len = @intCast(count) };
    }

    inline for (@typeInfo(std.meta.Child(@TypeOf(source))).@"struct".field_names) |name| {
        if (@field(source, name).len != count) return error.InvalidAst;
    }

    if (count > std.math.maxInt(u32) - target.count()) return error.OutOfMemory;

    const start: u32 = @intCast(target.count());

    try target.reserve(allocator, count);

    for (0..count) |index| target.append(node.Field{
        .name = if (comptime borrow_text) source.name[index] else try allocator.dupe(u8, source.name[index]),
        .value = @fromBackingInt(source.value[index]),
        .default_value = if (source.default_value[index]) |id| @fromBackingInt(id) else null,
        .comptime_parameter = source.comptime_parameter[index],
    });

    return .{ .start = start, .len = @intCast(count) };
}

pub fn bindColumns(target: anytype, source: anytype, comptime borrow_text: bool) [4]transfer.Column {
    return .{
        transfer.bind(&target.fields.name.values, source.name, true, borrow_text),
        transfer.bind(&target.fields.value.values, source.value, false, true),
        transfer.bind(&target.fields.default_value.values, source.default_value, false, true),
        transfer.bind(&target.fields.comptime_parameter.values, source.comptime_parameter, false, true),
    };
}
