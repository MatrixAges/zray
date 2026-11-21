const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const generated = @import("genz_options").generated_analysis;

pub fn field(self: *Lower, target: node.ExpressionId, name: []const u8) Lower.Error!node.ExpressionId {
    if (!generated) return self.builder.expression(.{ .field = .{ .target = target, .name = name } });

    const entry = @import("generated_field_access");
    const Input = std.meta.Child(entry.Input);
    const input: Input = .{ .target = @backingInt(target), .name = name };
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const output = try zx.columns.invoke(entry.executeValue, memory.allocator(), &input);
    const rows = zx.columns.view(std.meta.Child(entry.Output), output);
    const root = self.builder.nodes.expressions.tags.items.len;

    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.expressions, &rows) catch |err| return failure(err);

    return @fromBackingInt(@intCast(root));
}

pub fn dereference(self: *Lower, value: node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!generated) return self.builder.expression(.{ .dereference = value });

    const entry = @import("generated_dereference_access");
    const Input = std.meta.Child(entry.Input);
    const input: Input = .{ .value = @backingInt(value) };
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const output = try zx.columns.invoke(entry.executeValue, memory.allocator(), &input);
    const rows = zx.columns.view(std.meta.Child(entry.Output), output);
    const root = self.builder.nodes.expressions.tags.items.len;

    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.expressions, &rows) catch |err| return failure(err);

    return @fromBackingInt(@intCast(root));
}

pub fn length(self: *Lower, source: node.ExpressionId, type_expr: node.ExpressionId, buffered: bool) Lower.Error!node.ExpressionId {
    if (!generated) return self.cast(type_expr, try self.field(source, "len"));

    const entry = @import("generated_length_access");

    const input: std.meta.Child(entry.Input) = .{
        .source = @backingInt(source),
        .type_expr = @backingInt(type_expr),
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .buffered = buffered,
    };

    return castRows(self, entry, &input);
}

pub fn optional(self: *Lower, type_expr: ?node.ExpressionId, value: ?node.ExpressionId) Lower.Error!node.ExpressionId {
    if (!generated) {
        if (type_expr) |target| return self.cast(target, value orelse try self.builder.expression(.null_value));

        return self.builder.expression(.{ .optional_unwrap = value.? });
    }

    const entry = @import("generated_optional_access");

    const input: std.meta.Child(entry.Input) = .{
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .type_expr = if (type_expr) |id| @backingInt(id) else null,
        .value = if (value) |id| @backingInt(id) else null,
    };

    return castRows(self, entry, &input);
}

pub fn fieldPath(self: *Lower, value: node.ExpressionId, names: []const []const u8) Lower.Error!node.ExpressionId {
    if (names.len == 0) return value;
    if (names.len == 1) return field(self, value, names[0]);

    const entry = @import("generated_projection_fields");

    const input: std.meta.Child(entry.Input) = .{
        .names = names,
        .target = @backingInt(value),
        .base = @intCast(self.builder.nodes.expressions.tags.items.len),
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [1024]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = zx.columns.invoke(entry.executeValue, memory.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!output.valid) return error.OutOfMemory;

    const rows = zx.columns.view(std.meta.Child(@FieldType(std.meta.Child(entry.Output), "rows")), output.rows);
    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.expressions, &rows) catch |err| return failure(err);

    return @fromBackingInt(output.root);
}

fn castRows(self: *Lower, comptime entry: type, input: *const std.meta.Child(entry.Input)) Lower.Error!node.ExpressionId {
    var buffer: [1024]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const output = zx.columns.invoke(entry.executeValue, memory.allocator(), input) catch |err| return failure(err);

    if (!output.valid) return error.OutOfMemory;

    var rows = zx.columns.view(std.meta.Child(@FieldType(std.meta.Child(entry.Output), "rows")), output.rows);
    const arguments = if (rows.builtin_arguments.len == 0) &.{} else try self.allocator.dupe(u32, rows.builtin_arguments[0]);
    const retained = [_][]const u32{arguments};

    if (rows.builtin_arguments.len != 0) rows.builtin_arguments = &retained;
    @import("../../node/import_rows.zig").appendBorrowed(self.allocator, &self.builder.nodes.expressions, &rows) catch |err| return failure(err);

    return @fromBackingInt(output.root);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
