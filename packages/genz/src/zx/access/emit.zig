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

pub fn length(self: *Lower, source: node.ExpressionId, type_expr: node.ExpressionId, _: bool) Lower.Error!node.ExpressionId {
    return self.cast(type_expr, try self.field(source, "len"));
}

pub fn optional(self: *Lower, type_expr: ?node.ExpressionId, value: ?node.ExpressionId) Lower.Error!node.ExpressionId {
    if (type_expr) |target| return self.cast(target, value orelse try self.builder.expression(.null_value));

    return self.builder.expression(.{ .optional_unwrap = value.? });
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
