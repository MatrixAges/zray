const std = @import("std");
const zx = @import("zx");
const transfer = zx.memory.column_transfer;
const headers = @import("headers.zig");
const generated = @import("genz_options").generated_analysis;
const Layout = enum { dense, selected };

pub fn append(allocator: std.mem.Allocator, target: anytype, source: anytype, counts: *const headers.Counts(@TypeOf(target)), comptime layout: Layout, comptime copy_payloads: bool, comptime borrow_text: bool) headers.Error!void {
    @setEvalBranchQuota(100_000);

    if (source.tags.len == 0) return;

    const names = @typeInfo(@TypeOf(target.payloads)).@"struct".field_names;
    const View = std.meta.Child(@TypeOf(source));
    const width = comptime fields(@TypeOf(target.payloads), View);

    if (!generated) {
        try target.tags.ensureUnusedCapacity(allocator, source.tags.len);
        try target.offsets.ensureUnusedCapacity(allocator, source.offsets.len);
    }

    var buffers: [width]transfer.Column = undefined;
    var groups: [names.len][]const transfer.Column = undefined;
    comptime var first: usize = 0;

    inline for (names, counts, &groups) |name, count, *group| {
        const column = &@field(target.payloads, name);
        const end = first + comptime widthOf(std.meta.Child(@TypeOf(column)), View, name);

        if (count != 0) {
            if (!generated) try column.reserve(allocator, count);

            attach(column, source, name, buffers[first..end], copy_payloads, borrow_text);

            group.* = buffers[first..end];
        } else group.* = &.{};

        first = end;
    }

    const rows: transfer.Groups = &groups;
    const Tag = std.meta.Elem(@TypeOf(target.tags.items));
    const tags = @as([*]const Tag, @ptrCast(source.tags.ptr))[0..source.tags.len];

    if (!generated) return @import("import_payloads/seed.zig").append(allocator, target, tags, source.offsets, counts, rows, layout == .selected);

    const entry = @import("generated_node_payload_append");
    var bases: headers.Counts(@TypeOf(target)) = undefined;
    const bases_view: []u32 = &bases;
    const lengths: zx.memory.ColumnLengths = &.{ &target.tags.items.len, &target.offsets.items.len };
    var views: headers.Views = .{};

    const input = input: {
        var request = views.bind(std.meta.Child(entry.Input), &allocator, target, &lengths);

        request.tags = std.mem.sliceAsBytes(tags);
        request.offsets = source.offsets;
        request.mask = headers.mask(Tag);
        request.bases = @ptrCast(&bases_view);
        request.groups = @ptrCast(&rows);
        request.counts = counts;
        request.layout = if (comptime layout == .selected) .Selected else .Dense;

        break :input request;
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const complete = zx.columns.invoke(entry.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!complete) return error.OutOfMemory;
}

fn fields(comptime Payloads: type, comptime View: type) usize {
    var total: usize = 0;

    for (@typeInfo(Payloads).@"struct".field_names) |name| {
        total += widthOf(@FieldType(Payloads, name), View, name);
    }

    return total;
}

fn widthOf(comptime Column: type, comptime View: type, comptime prefix: []const u8) usize {
    if (@hasField(Column, "fields")) {
        const Fields = @FieldType(Column, "fields");
        var count: usize = 0;

        for (@typeInfo(Fields).@"struct".field_names) |name| {
            count += widthOf(@FieldType(Fields, name), View, prefix ++ "_" ++ name);
        }

        return count;
    }

    const Value = std.meta.Elem(@FieldType(@FieldType(Column, "values"), "items"));

    return @intFromBool(Value == void or @hasField(View, prefix));
}

fn attach(column: anytype, source: anytype, comptime prefix: []const u8, buffers: []transfer.Column, comptime copy_payloads: bool, comptime borrow_text: bool) void {
    const Column = std.meta.Child(@TypeOf(column));
    const View = std.meta.Child(@TypeOf(source));

    if (@hasField(Column, "fields")) {
        comptime var start: usize = 0;

        inline for (@typeInfo(@TypeOf(column.fields)).@"struct".field_names) |name| {
            const child = &@field(column.fields, name);
            const path = prefix ++ "_" ++ name;
            const end = start + comptime widthOf(std.meta.Child(@TypeOf(child)), View, path);

            attach(child, source, path, buffers[start..end], copy_payloads, borrow_text);

            start = end;
        }
    } else if (std.meta.Elem(@TypeOf(column.values.items)) == void) {
        buffers[0] = transfer.bind(&column.values, @as([]const void, &.{}), copy_payloads, borrow_text);
    } else if (@hasField(View, prefix)) {
        buffers[0] = transfer.bind(&column.values, @field(source, prefix), copy_payloads, borrow_text);
    }
}
