const std = @import("std");
const zx = @import("zx");
const transfer = zx.memory.column_transfer;
const headers = @import("headers.zig");
const Layout = enum { dense, selected };
const GroupsView = @FieldType(std.meta.Child(@import("generated_node_payload_import").Input), "groups");
const field_count = @typeInfo(@import("../node.zig").Field).@"struct".field_names.len;

pub const Plain = struct {
    columns: []const transfer.Column = undefined,
    initial: usize = undefined,
    description: transfer.Description(GroupsView, 1, field_count) = .{},
    pub fn bind(self: *Plain, comptime Input: type, allocator: *const std.mem.Allocator, columns: []const transfer.Column, lengths: []?u64, count: usize, existing: usize, borrowed: bool) Input {
        self.columns = columns;
        self.initial = existing;

        return plainInput(Input, self.description.bind(&.{columns}), allocator, columns, lengths, count, existing, borrowed);
    }

    pub fn rollback(self: *const Plain, allocator: *const std.mem.Allocator) void {
        rollbackGroups(allocator.*, &.{self.columns}, &.{self.initial});
    }
    pub fn append(allocator: std.mem.Allocator, columns: anytype, count: usize, existing: usize, borrowed: bool) headers.Error!void {
        const entry = @import("generated_node_plain_append");
        const Input = std.meta.Child(entry.Input);
        var lengths: [columns.len]?u64 = undefined;
        var description: transfer.Description(GroupsView, 1, columns.len) = .{};
        const input = plainInput(Input, description.bind(&.{columns}), &allocator, columns, &lengths, count, existing, borrowed);

        return invoke(entry.executeValue, &input);
    }
    pub fn appendBorrowedRows(allocator: std.mem.Allocator, target: anytype, rows: anytype) std.mem.Allocator.Error!void {
        if (rows.len == 0) return;

        const names = @typeInfo(@TypeOf(target.fields)).@"struct".field_names;
        const Row = std.meta.Elem(@TypeOf(rows));
        var columns: [names.len]transfer.Column = undefined;

        inline for (names, &columns) |name, *column| {
            const values = &@field(target.fields, name).values;

            comptime @import("view.zig").compatible(@FieldType(Row, name), std.meta.Elem(@TypeOf(values.items)));

            column.* = transfer.borrowRowField(values, name, rows);
        }

        return Plain.append(allocator, &columns, rows.len, target.count(), true) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidAst => unreachable,
        };
    }
};

fn plainInput(comptime Input: type, groups: GroupsView, allocator: *const std.mem.Allocator, columns: []const transfer.Column, lengths: []?u64, count: usize, existing: usize, borrowed: bool) Input {
    for (columns, lengths) |column, *length| length.* = column.sourceLength();

    return .{
        .allocator = @ptrCast(allocator),
        .groups = groups,
        .lengths = lengths,
        .count = count,
        .existing = existing,
        .borrowed = borrowed,
    };
}

pub fn Binding(comptime Target: type, comptime View: type, comptime layout: Layout) type {
    const Payloads = @FieldType(std.meta.Child(Target), "payloads");
    const names = @typeInfo(Payloads).@"struct".field_names;
    const width = fields(Payloads, View);

    const complete = comptime complete: {
        @setEvalBranchQuota(100_000);

        var supplied: [names.len]bool = undefined;
        var present: usize = 2;

        for (names, &supplied) |name, *flag| {
            const shape = sourceShape(@FieldType(Payloads, name), View, name, layout);

            flag.* = shape.complete;
            present += shape.present;
        }

        if (present != @typeInfo(View).@"struct".field_names.len) @compileError("AST import has unknown columns");

        break :complete supplied;
    };

    return struct {
        const Self = @This();

        buffers: [width]transfer.Column = undefined,
        slices: [names.len][]const transfer.Column = undefined,
        source_lengths: [width]?u64 = undefined,
        source_groups: [names.len][]const ?u64 = undefined,
        initial: [names.len]usize = undefined,
        description: transfer.Description(GroupsView, names.len, width) = .{},
        pub fn bind(self: *Self, comptime Input: type, allocator: *const std.mem.Allocator, target: Target, source: *const View, comptime copy_payloads: bool, comptime borrow_text: bool) Input {
            @setEvalBranchQuota(100_000);

            const Tag = std.meta.Elem(@TypeOf(target.tags.items));

            comptime @import("view.zig").compatible(Tag, std.meta.Elem(@FieldType(View, "tags")));

            comptime var first: usize = 0;

            inline for (names, &self.slices, &self.source_groups, &self.initial) |name, *group, *source_group, *count| {
                const column = &@field(target.payloads, name);
                const end = first + comptime widthOf(std.meta.Child(@TypeOf(column)), View, name);

                attach(column, source, name, self.buffers[first..end], copy_payloads, borrow_text);

                group.* = self.buffers[first..end];
                source_group.* = self.source_lengths[first..end];

                for (group.*, self.source_lengths[first..end]) |descriptor, *length| {
                    length.* = descriptor.sourceLength();
                }

                count.* = if (group.len == 0) 0 else group.*[0].storage.items.len;
                first = end;
            }

            var input: Input = undefined;

            if (@hasField(Input, "allocator")) {
                input.allocator = @ptrCast(allocator);
                input.groups = self.description.bind(&self.slices);
                input.layout = if (layout == .selected) .Selected else .Dense;

                input.reserved = target.tags.items.len <= std.math.maxInt(u32) and
                    source.tags.len <= std.math.maxInt(u32) - target.tags.items.len and
                    reserveHeaders(allocator.*, target, source.tags.len);
            }

            input.tags = std.mem.sliceAsBytes(source.tags);
            input.offsets = source.offsets;
            input.mask = headers.mask(Tag);
            input.lengths = &self.source_groups;
            input.complete = &complete;
            input.existing = target.tags.items.len;

            if (@hasField(Input, "selected")) {
                input.selected = layout == .selected;
            }

            return input;
        }

        pub fn rollback(self: *const Self, allocator: *const std.mem.Allocator) void {
            rollbackGroups(allocator.*, &self.slices, &self.initial);
        }
    };
}

fn rollbackGroups(allocator: std.mem.Allocator, groups: transfer.Groups, initial: []const usize) void {
    for (groups, initial) |group, count| {
        if (group.len == 0) continue;

        const added = group[0].storage.items.len - count;

        if (added == 0) continue;
        for (group) |column| column.storage.items.len = count;

        transfer.discard(allocator, group, added);
    }
}

const Shape = struct { present: usize, complete: bool };

fn sourceShape(comptime Column: type, comptime View: type, comptime prefix: []const u8, comptime layout: Layout) Shape {
    if (@hasField(Column, "fields")) {
        const Fields = @FieldType(Column, "fields");
        var shape: Shape = .{ .present = 0, .complete = true };

        for (@typeInfo(Fields).@"struct".field_names) |name| {
            const child = sourceShape(@FieldType(Fields, name), View, prefix ++ "_" ++ name, layout);

            shape.present += child.present;
            shape.complete = shape.complete and child.complete;
        }

        return shape;
    }

    const Value = std.meta.Elem(@FieldType(@FieldType(Column, "values"), "items"));
    const present = @hasField(View, prefix);

    if (present and (Value != void or layout == .selected)) {
        @import("view.zig").compatible(Value, std.meta.Elem(@FieldType(View, prefix)));
    }

    return .{ .present = @intFromBool(present), .complete = present or Value == void };
}

pub fn append(allocator: std.mem.Allocator, target: anytype, source: anytype, comptime layout: Layout, comptime copy_payloads: bool, comptime borrow_text: bool) headers.Error!void {
    const entry = @import("generated_node_payload_import");
    var binding: Binding(@TypeOf(target), std.meta.Child(@TypeOf(source)), layout) = .{};
    const input = binding.bind(std.meta.Child(entry.Input), &allocator, target, source, copy_payloads, borrow_text);
    var scratch_buf: [2048]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();

    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());

    const result = zx.columns.invoke(entry.executeValue, fallback.allocator(), &input) catch |err| {
        binding.rollback(&allocator);

        return failure(err);
    };

    appendHeaders(target, source.tags, result);

    return switch (result.check) {
        .Valid => {},
        .Invalid => error.InvalidAst,
        .Exhausted => error.OutOfMemory,
    };
}

pub fn appendHeaders(target: anytype, tags: anytype, result: anytype) void {
    const count: usize = @intCast(result.count);

    if (count == 0) return;

    const Tag = std.meta.Elem(@TypeOf(target.tags.items));
    const selected: []const Tag = @ptrCast(tags[0..count]);

    target.tags.appendSliceAssumeCapacity(selected);
    target.offsets.appendSliceAssumeCapacity(result.offsets[0..count]);
}

fn reserveHeaders(allocator: std.mem.Allocator, target: anytype, count: usize) bool {
    target.tags.ensureUnusedCapacity(allocator, count) catch return false;
    target.offsets.ensureUnusedCapacity(allocator, count) catch return false;

    return true;
}

pub fn check(target: anytype, source: anytype, comptime layout: Layout) headers.Error!headers.Counts(@TypeOf(target)) {
    const entry = @import("generated_node_payload_validate");
    var binding: Binding(@TypeOf(target), std.meta.Child(@TypeOf(source)), layout) = .{};
    const input = binding.bind(std.meta.Child(entry.Input), undefined, target, source, false, true);
    var scratch_buf: [2048]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();

    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());
    const result = zx.columns.invoke(entry.executeValue, fallback.allocator(), &input) catch |err| return failure(err);

    switch (result.check) {
        .Valid => {},
        .Invalid => return error.InvalidAst,
        .Exhausted => return error.OutOfMemory,
    }

    var counts: headers.Counts(@TypeOf(target)) = undefined;

    @memcpy(&counts, result.counts);

    return counts;
}

pub fn appendSeed(allocator: std.mem.Allocator, target: anytype, source: anytype, counts: *const headers.Counts(@TypeOf(target)), comptime layout: Layout, comptime copy_payloads: bool, comptime borrow_text: bool) headers.Error!void {
    @setEvalBranchQuota(100_000);

    if (source.tags.len == 0) return;

    const names = @typeInfo(@TypeOf(target.payloads)).@"struct".field_names;
    const View = std.meta.Child(@TypeOf(source));
    const width = comptime fields(@TypeOf(target.payloads), View);

    try target.tags.ensureUnusedCapacity(allocator, source.tags.len);
    try target.offsets.ensureUnusedCapacity(allocator, source.offsets.len);

    var buffers: [width]transfer.Column = undefined;
    var groups: [names.len][]const transfer.Column = undefined;
    comptime var first: usize = 0;

    inline for (names, counts, &groups) |name, count, *group| {
        const column = &@field(target.payloads, name);
        const end = first + comptime widthOf(std.meta.Child(@TypeOf(column)), View, name);

        if (count != 0) {
            try column.reserve(allocator, count);

            attach(column, source, name, buffers[first..end], copy_payloads, borrow_text);

            group.* = buffers[first..end];
        } else group.* = &.{};

        first = end;
    }

    const rows: transfer.Groups = &groups;
    const Tag = std.meta.Elem(@TypeOf(target.tags.items));
    const tags = @as([*]const Tag, @ptrCast(source.tags.ptr))[0..source.tags.len];

    return @import("import_payloads/seed.zig").append(allocator, target, tags, source.offsets, counts, rows, layout == .selected);
}

pub fn invoke(comptime execute: anytype, input: anytype) headers.Error!void {
    var scratch_buf: [2048]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();

    var fallback = std.heap.BufferFirstAllocator.init(&scratch_buf, arena.allocator());
    const result = zx.columns.invoke(execute, fallback.allocator(), input) catch |err| return failure(err);

    return switch (result) {
        .Valid => {},
        .Invalid => error.InvalidAst,
        .Exhausted => error.OutOfMemory,
    };
}

pub fn failure(err: anyerror) headers.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        error.IndexOutOfBounds => error.InvalidAst,
        else => unreachable,
    };
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
